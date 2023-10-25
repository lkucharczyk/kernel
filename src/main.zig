const std = @import( "std" );
const arch = @import( "./x86.zig" );
const com = @import( "./com.zig" );
const kbd = @import( "./kbd.zig" );
const mem = @import( "./mem.zig" );
const tty = @import( "./tty.zig" );
const multiboot = @import( "./multiboot.zig" );
const Stream = @import( "./util/stream.zig" ).Stream;
const MultiWriter = @import( "./util/stream.zig" ).MultiWriter;

var logStreams: [2]?Stream = .{ null, null };
pub var log = MultiWriter { .streams = &logStreams };
pub const panic = @import( "./panic.zig" ).panic;

pub const os = struct {
	pub const system = struct {};
};

export const mbHeader: multiboot.Header align(4) linksection(".multiboot") = multiboot.Header.init( .{
	.pageAlign = true,
	.memInfo = true
} );

export var kstack: [64 * 1024]u8 align(4096) linksection(".bss.stack") = undefined;
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
		\\ addl $0xc0000000, %%ebx
		\\ pushl %%ebx
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

	if ( mbMagic == multiboot.Info.MAGIC ) {
		log.printUnsafe( "multiboot: {x:0>8}\n{any}\n\n", .{ mbMagic, mbInfo } );
	}

	if ( @import( "./acpi/rsdp.zig" ).init() ) |rsdp| {
		log.printUnsafe( "rsdp: {*}\n{}\n\n", .{ rsdp, rsdp } );
	}

	kbd.init();

	var buf: [1]u8 = .{ 0 };
	while ( ( kbd.read( null, &buf ) catch unreachable ) > 0 ) {
		_ = log.write( &buf ) catch unreachable;
	}
	// if ( com.ports[0] ) |com0| {
	// 	while ( com0.read( &buf ) > 0 ) {
	// 		_ = log.write( &buf ) catch unreachable;
	// 	}
	// }

	// arch.halt();
	@panic( "kmain end" );
}
