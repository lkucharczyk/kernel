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

	// enable protected mode, FPU and SSE
	asm volatile (
		\\ movl %%cr0, %%ecx
		\\ and $0xfff1, %%cx // enable FPU
		\\ orl $0x01, %%ecx  // enable PM
		\\ movl %%ecx, %%cr0

		\\ movl %%cr4, %%ecx
		\\ orl $0x600, %%ecx // enable SSE
		\\ movl %%ecx, %%cr4

		\\ jmp $0x08, $kmain_pm
		\\ kmain_pm:
	);

	if ( mbMagic == multiboot.Info.MAGIC ) {
		mem.init( mbInfo );
	} else {
		mem.init( null );
	}

	ktry( vfs.init() );

	tty.init();
	logStreams[0] = tty.stream();

	com.init();
	if ( com.ports[0] ) |*com0| {
		logStreams[1] = com0.stream();
	}

	var testExec: ?[]const u8 = null;
	if ( mbMagic == multiboot.Info.MAGIC ) {
		if ( mbInfo.?.getCmdline() ) |cmd| {
			if ( std.mem.indexOf( u8, cmd, " --test " ) ) |i| {
				testExec = cmd[( i + 8 )..];
				logStreams[0] = null;
				logStreams[1] = null;
			}
		}
	}

	@import( "./idt.zig" ).init();
	@import( "./isr.zig" ).init();
	@import( "./irq.zig" ).init();

	log.printUnsafe( "mem.kbrk: {x:0>8}\n\n", .{ mem.kbrk } );

	if ( mbMagic == multiboot.Info.MAGIC ) {
		log.printUnsafe( "multiboot: {x:0>8}\n{?}\nbootloader: {}\ncmdline: {?}\n", .{
			mbMagic, mbInfo,
			fmtUtil.OptionalCStr { .data = mbInfo.?.getBootloaderName() },
			fmtUtil.OptionalStr { .data = mbInfo.?.getCmdline() }
		} );

		if ( mbInfo.?.getMemoryMap() ) |mmap| {
			log.writeUnsafe( "mmap:\n" );
			for ( mmap ) |entry| {
				log.printUnsafe( "    - {}\n", .{ entry } );
			}
		}

		if ( mbInfo.?.getModules() ) |modules| {
			log.printUnsafe( "modules:\n", .{} );
			// const modulesNode: *vfs.Node = ktry( vfs.rootNode.mkdir( "mods" ) );

			for ( modules ) |module| {
				log.printUnsafe( "    - {}\n", .{ module } );

				const node = ktry( vfs.rootVfs.createRoFile( module.getData() ) );
				// const name = [4:0]u8 { 'm', 'o', 'd', '0' + @as( u8, @truncate( i ) ) };
				// ktry( modulesNode.link( node, &name ) );

				if ( module.getCmdline() ) |cmdline| {
					const cmd = std.mem.sliceTo( cmdline, 0 );
					var targetIter = if ( std.mem.startsWith( u8, cmd, "./zig-out/" ) ) (
						std.mem.splitScalar( u8, cmd[9..], ' ' )
					) else if ( std.mem.indexOfScalar( u8, cmd, ' ' ) ) |p| (
						std.mem.splitScalar( u8, cmd[( p + 1 )..], ' ' )
					) else {
						continue;
					};

					while ( targetIter.next() ) |target| {
						var dir = vfs.rootNode;
						var partIter = std.mem.splitScalar( u8, target[1..], '/' );

						while ( partIter.next() ) |part| {
							if ( dir.resolve( part ) ) |next| {
								std.debug.assert( next.ntype == .Directory );
								dir = next;
							} else {
								if ( partIter.peek() == null ) {
									_ = ktry( dir.link( node, part ) );
									break;
								} else {
									dir = ktry( dir.mkdir( part ) );
								}
							}
						}
					}
				}
			}
		}

		log.writeUnsafe( "\n" );
	} else {
		log.writeUnsafe( "multiboot: magic invalid!\n\n" );
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

				log.writeUnsafe( "\n" );
			} else {
				log.writeUnsafe( "acpi: rsdt validation failed!\n\n" );
			}
		} else {
			log.writeUnsafe( "acpi: rsdp validation failed!\n\n" );
		}
	} else {
		log.writeUnsafe( "acpi: rsdp missing!\n\n" );
	}

	@import( "./pit.zig" ).init( 100 );
	syscall.init();
	ktry( task.init() );
	@import( "./panic.zig" ).earlyPanic = false;

	@import( "./rtc.zig" ).init();
	log.writeUnsafe( "\n" );

	ktry( @import( "./pci.zig" ).init() );
	kbd.init();
	log.writeUnsafe( "\n" );

	if ( testExec == null ) {
		ktry( @import( "./net.zig" ).init() );
		ktry( @import( "./drivers/rtl8139.zig" ).init() );
		log.writeUnsafe( "\n" );

		vfs.printTree( vfs.rootNode, "[RootVFS]", 0 );
		log.writeUnsafe( "\n" );
	}

	if ( testExec ) |cmd| {
		var iter = std.mem.splitScalar( u8, cmd, ' ' );

		const path = iter.next().?;
		if ( vfs.rootNode.resolveDeep( path[1..] ) ) |node| {
			var elf: *vfs.FileDescriptor = ktry( node.open() );
			defer elf.close();

			var args = std.ArrayList( [*:0]const u8 ).init( kheap );
			while ( iter.next() ) |arg| {
				ktry( args.append( ktry( kheap.dupeZ( u8, arg ) ) ) );
			}

			_ = ktry( task.createElf(
				elf.reader(),
				elf.seekableStream(),
				ktry( kheap.dupeZ( u8, path ) ),
				.{ args.items, &.{} }
			) );
		} else {
			log.streams[0] = com.ports[0].?.stream();
			std.debug.panic( "Missing test init elf: \"{s}\"", .{ path } );
		}

		arch.enableInterrupts();
		task.schedule();

		arch.out( u16, 0x0604, 0x2000 );
	}

	if ( vfs.rootNode.resolveDeep( "bin/shell" ) ) |node| {
		var elf: *vfs.FileDescriptor = ktry( node.open() );
		defer elf.close();

		const env = .{ "PATH=/bin" };

		inline for ( 0..com.ports.len ) |i| {
			if ( com.ports[i] ) |_| {
				const path = std.fmt.comptimePrint( "/dev/com{}", .{ i } );
				_ = ktry( task.createElf(
					elf.reader(),
					elf.seekableStream(),
					"/bin/shell",
					.{ &.{ "/bin/shell", path, path }, &env }
				) );
			}
		}

		_ = ktry( task.createElf(
			elf.reader(),
			elf.seekableStream(),
			"/bin/shell",
			.{ &.{ "/bin/shell", "/dev/kbd0", "/dev/tty0" }, &env }
		) );
	}

	arch.enableInterrupts();
	task.schedule();

	// arch.halt();
	@panic( "kmain end" );
}
