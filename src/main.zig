const std = @import( "std" );
const arch = @import( "./x86.zig" );
const com = @import( "./com.zig" );
const kbd = @import( "./kbd.zig" );
const mem = @import( "./mem.zig" );
const syscall = @import( "./syscall.zig" );
const task = @import( "./task.zig" );
const tty = @import( "./tty.zig" );
const multiboot = @import( "./multiboot.zig" );
const fmtUtil = @import( "./util/fmt.zig" );
const Stream = @import( "./util/stream.zig" ).Stream;
const MultiWriter = @import( "./util/stream.zig" ).MultiWriter;

var logStreams: [2]?Stream = .{ null, null };
pub var log = MultiWriter { .streams = &logStreams };
pub const panic = @import( "./panic.zig" ).panic;

pub const os = struct {
	pub const heap = struct {
		pub const page_allocator = mem.kheapFba.allocator();
	};

	pub const system = struct {
		pub const sockaddr = std.os.linux.sockaddr;
	};
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
		:: [ptr] "{ecx}" ( @intFromPtr( &mem.pagingDir ) )
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

	mem.pagingDir.entries[0].flags.present = false;
	asm volatile ( "invlpg (0)" );

	@import( "./vfs.zig" ).init() catch unreachable;

	tty.init();
	logStreams[0] = tty.stream();

	com.init();
	if ( com.ports[0] ) |*com0| {
		logStreams[1] = com0.stream();
	}

	@import( "./idt.zig" ).init();
	@import( "./isr.zig" ).init();
	@import( "./irq.zig" ).init();
	arch.enableInterrupts();

	mem.init();

	if ( mbMagic == multiboot.Info.MAGIC ) {
		log.printUnsafe( "multiboot: {x:0>8}\n{?}\nbootloader: {}\ncmdline: {?}\n", .{
			mbMagic, mbInfo,
			fmtUtil.OptionalCStr { .data = mbInfo.?.getBootloaderName() },
			fmtUtil.OptionalCStr { .data = mbInfo.?.getCmdline() } }
		);

		if ( mbInfo.?.getMemoryMap() ) |mmap| {
			log.printUnsafe( "mmap:\n", .{} );
			for ( mmap ) |entry| {
				log.printUnsafe( "    - {}\n", .{ entry } );
			}
		}

		log.printUnsafe( "\n", .{} );
	} else {
		log.printUnsafe( "multiboot: magic invalid!\n\n", .{} );
	}

	if ( @import( "./acpi/rsdp.zig" ).init() ) |rsdp| {
		if ( rsdp.validate() ) {
			const rsdt = rsdp.getRsdt();
			if ( rsdt.validate() ) {
				log.printUnsafe(
					"rsdp: {[0]*} {[0]}\nrsdt: {[1]*} {[2]}\n",
					.{ rsdp, rsdt, std.fmt.Formatter( @import( "./acpi/rsdt.zig" ).Rsdt.format ) { .data = rsdt } }
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
	@import( "./pci.zig" ).init() catch unreachable;
	kbd.init();
	log.printUnsafe( "\n", .{} );

	syscall.init();
	task.init() catch unreachable;

	@import( "./net.zig" ).init() catch unreachable;
	@import( "./drivers/rtl8139.zig" ).init() catch unreachable;

	@import( "./vfs.zig" ).printTree( @import( "./vfs.zig" ).rootNode, 0 );

	inline for ( 0..com.ports.len ) |i| {
		if ( com.ports[i] ) |_| {
			const path = std.fmt.comptimePrint( "/dev/com{}", .{ i } );
			_ = task.create( @import( "./shell.zig" ).task( path, path ), false );
		}
	}
	_ = task.create( @import( "./shell.zig" ).task( "/dev/kbd0", "/dev/tty0" ), false );
	task.schedule();

	// arch.halt();
	@panic( "kmain end" );
}
