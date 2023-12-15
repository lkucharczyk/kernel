const std = @import( "std" );
const com = @import( "./com.zig" );
const kbd = @import( "./kbd.zig" );
const mem = @import( "./mem.zig" );
const syscall = @import( "./syscall.zig" );
const task = @import( "./task.zig" );
const tty = @import( "./tty.zig" );
const vfs = @import( "./vfs.zig" );
const multiboot = @import( "./multiboot.zig" );
const fmtUtil = @import( "./util/fmt.zig" );
const Stream = @import( "./util/stream.zig" ).Stream;
const MultiWriter = @import( "./util/stream.zig" ).MultiWriter;

var logStreams: [2]?Stream = .{ null, null };
pub var log = MultiWriter { .streams = &logStreams };
pub const panic = @import( "./panic.zig" ).panic;

pub const arch = @import( "./x86.zig" );
pub const os = struct {
	pub const heap = struct {
		pub const page_allocator = std.mem.Allocator {
			.ptr = &mem.kheapSbrk,
			.vtable = &@TypeOf( mem.kheapSbrk ).vtable
		};
	};

	pub const system = @import( "./api/system.zig" );
};

export const mbHeader: multiboot.Header align(4) linksection(".multiboot") = multiboot.Header.init( .{
	.pageAlign = true,
	.memInfo = true
} );

pub const kheap = mem.kheapGpa.allocator();

extern const ADDR_KSTACK_END: u8;

export fn _start() align(16) linksection(".text.boot") callconv(.Naked) noreturn {
	// enable paging
	asm volatile (
		\\ movl %[ptr], %%cr3
		:: [ptr] "{ecx}" ( @intFromPtr( &mem._pagingDir ) )
	);
	asm volatile (
		\\ movl %%cr4, %%ecx
		\\ orl $0x00000010, %%ecx
		\\ movl %%ecx, %%cr4

		\\ movl %%cr0, %%ecx
		\\ orl $0x80000000, %%ecx
		\\ movl %%ecx, %%cr0
	);

	asm volatile ( "jmp _startHigh" );
	arch.halt();
}

export fn _startHigh() align(16) linksection(".text") callconv(.Naked) noreturn {
	asm volatile ( "invlpg (0)" );

	// set stack pointer
	asm volatile (
		\\ subl $32, %[ptr]
		\\ movl %[ptr], %%ebp
		\\ movl %[ptr], %%esp
		:: [ptr] "{ecx}" ( @intFromPtr( &ADDR_KSTACK_END ) )
	);

	// push multiboot magic and info ptr
	asm volatile (
		\\ pushl %%eax
		\\ addl %[offset], %%ebx
		\\ pushl %%ebx
		:: [offset] "n" ( mem.ADDR_KMAIN_OFFSET )
	);

	asm volatile ( "call kmain" );
	arch.halt();
}

inline fn ktry( val: anytype ) @typeInfo( @TypeOf( val ) ).ErrorUnion.payload {
	return val catch |err| @panic( @errorName( err ) );
}

export fn kmain( mbInfo: ?*multiboot.Info, mbMagic: u32 ) linksection(".text") noreturn {
	@import( "./gdt.zig" ).init();

	// enable protected mode
	asm volatile (
		\\ movl %%cr0, %%eax
		\\ orl $0x01, %%eax
		\\ movl %%eax, %%cr0
		\\ jmp $0x08, $kmain_pm
		\\ kmain_pm:
	);

	mem.pagingDir.unmap( 0 );
	mem.init();

	ktry( vfs.init() );

	tty.init();
	logStreams[0] = tty.stream();

	com.init();
	if ( com.ports[0] ) |*com0| {
		logStreams[1] = com0.stream();
	}

	@import( "./idt.zig" ).init();
	@import( "./isr.zig" ).init();
	@import( "./irq.zig" ).init();

	var shell: ?[]const u8 = null;
	if ( mbMagic == multiboot.Info.MAGIC ) {
		log.printUnsafe( "multiboot: {x:0>8}\n{?}\nbootloader: {}\ncmdline: {?}\n", .{
			mbMagic, mbInfo,
			fmtUtil.OptionalCStr { .data = mbInfo.?.getBootloaderName() },
			fmtUtil.OptionalCStr { .data = mbInfo.?.getCmdline() }
		} );

		if ( mbInfo.?.getMemoryMap() ) |mmap| {
			log.printUnsafe( "mmap:\n", .{} );
			for ( mmap ) |entry| {
				log.printUnsafe( "    - {}\n", .{ entry } );
			}
		}

		if ( mbInfo.?.getModules() ) |modules| {
			log.printUnsafe( "modules:\n", .{} );
			const binNode: *vfs.Node = ktry( vfs.rootNode.mkdir( "bin" ) );
			const modulesNode: *vfs.Node = ktry( vfs.rootNode.mkdir( "mods" ) );

			for ( modules, 0.. ) |module, i| {
				log.printUnsafe( "    - {}\n", .{ module } );

				const name = [4:0]u8 { 'm', 'o', 'd', '0' + @as( u8, @truncate( i ) ) };
				ktry( modulesNode.link(
					ktry( vfs.rootVfs.createRoFile( &name, module.getData() ) )
				) );

				if ( module.getCmdline() ) |cmdline| {
					inline for ( .{
						.{ "kernel.dbg", vfs.rootNode, "kernel.dbg" },
						.{ "shell.elf", binNode, "shell" },
						.{ "sbase-box", binNode, "sbase-box" }
					} ) |data| {
						if ( std.mem.endsWith( u8, std.mem.sliceTo( cmdline, 0 ), data[0] ) ) {
							shell = module.getData();
							ktry( data[1].link(
								ktry( vfs.rootVfs.createRoFile( data[2], module.getData() ) )
							) );
						}
					}
				}
			}
		}

		log.printUnsafe( "\n", .{} );
	} else {
		log.printUnsafe( "multiboot: magic invalid!\n\n", .{} );
	}

	if ( @import( "./acpi/rsdp.zig" ).init() ) |rsdp| {
		if ( rsdp.validate() ) {
			log.printUnsafe( "rsdp: {[0]*} {[0]}\n", .{ rsdp } );

			const acpiOffset: u10 = @truncate( rsdp.rsdtAddr >> 22 );
			mem.pagingDir.map( ( mem.ADDR_KMAIN_OFFSET >> 22 ) + acpiOffset, acpiOffset, mem.PagingDir.Flags.KERNEL_HUGE_RO );

			// mem.physicalPages.set( acpiOffset );
			mem.physicalPages.setRangeValue( .{ .start = acpiOffset, .end = 1024 }, true );

			const rsdt = rsdp.getRsdt();
			if ( rsdt.validate() ) {
				log.printUnsafe(
					"rsdt: {[0]*} {[1]}\n",
					.{ rsdt, std.fmt.Formatter( @import( "./acpi/rsdt.zig" ).Rsdt.format ) { .data = rsdt } }
				);

				if ( rsdt.getTable( @import( "./acpi/fadt.zig" ).Fadt ) ) |fadt| {
					log.printUnsafe( "fadt: {[0]*} {[0]}\n", .{ fadt } );
				}

				log.printUnsafe( "\n", .{} );
			} else {
				log.printUnsafe( "acpi: rsdt validation failed!\n\n", .{} );
			}
		} else {
			log.printUnsafe( "acpi: rsdp validation failed!\n\n", .{} );
		}
	} else {
		log.printUnsafe( "acpi: rsdp missing!\n\n", .{} );
	}

	@import( "./pit.zig" ).init( 100 );
	ktry( @import( "./pci.zig" ).init() );
	kbd.init();
	log.printUnsafe( "\n", .{} );

	syscall.init();
	ktry( task.init() );
	@import( "./panic.zig" ).earlyPanic = false;

	ktry( @import( "./net.zig" ).init() );
	ktry( @import( "./drivers/rtl8139.zig" ).init() );
	log.printUnsafe( "\n", .{} );

	@import( "./vfs.zig" ).printTree( @import( "./vfs.zig" ).rootNode, 0 );
	log.printUnsafe( "\n", .{} );

	if ( vfs.rootNode.resolveDeep( "bin/shell" ) ) |node| {
		var elf: *vfs.FileDescriptor = ktry( node.open() );
		defer elf.close();

		inline for ( 0..com.ports.len ) |i| {
			if ( com.ports[i] ) |_| {
				const path = std.fmt.comptimePrint( "/dev/com{}", .{ i } );
				const st = ktry( task.createElf( elf.reader(), elf.seekableStream(), .{ &.{ "/bin/shell", path, path }, &.{} } ) );
				st.bin = ktry( kheap.dupeZ( u8, "/bin/shell" ) );
			}
		}

		{
			const st = ktry( task.createElf( elf.reader(), elf.seekableStream(), .{ &.{ "/bin/shell", "/dev/kbd0", "/dev/tty0" }, &.{} } ) );
			st.bin = ktry( kheap.dupeZ( u8, "/bin/shell" ) );
		}
	}

	arch.enableInterrupts();
	task.schedule();

	// arch.halt();
	@panic( "kmain end" );
}
