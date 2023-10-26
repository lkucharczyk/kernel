const std = @import( "std" );
const root = @import( "root" );
const tty = @import( "./tty.zig" );
const x86 = @import( "./x86.zig" );

const MSG_EXCEPTION = [_][]const u8{
	"division by zero",
	"debug",
	"non maskable interrupt",
	"breakpoint",
	"overflow",
	"out-of-bounds",
	"invalid opcode",
	"no coprocessor",
	"double fault",
	"coprocessor segment overrun",
	"invalid TSS",
	"segment not present",
	"stack fault",
	"general protection",
	"page fault",
	"unknown (15)",
	"x87 FPU / coprocessor fault",
	"aligment check",
	"machine check",
	"SIMD floating point",
	"virtualization",
	"control protection",
	"unknown (22)",
	"unknown (23)",
	"unknown (24)",
	"unknown (25)",
	"unknown (26)",
	"unknown (27)",
	"hypervisor injection",
	"VMM communication",
	"security",
	"unknown (31)"
};

export const symbolTable: [32 * 1024]u8 align(4096) = .{ 0xde, 0xad, 0xbe, 0xef } ** ( 32 * 256 );

const Symbol = struct {
	address: usize,
	size: usize,
	name: []const u8
};

fn readAddress( buf: []const u8 ) u32 {
	var out: u32 = 0;

	for ( buf[0..4], 0..4 ) |c, i| {
		out |= @as( u32, @intCast( c ) ) << ( @as( u5, @intCast( 3 - i ) ) * 8 );
	}

	return out;
}

fn getSymbol( address: usize ) ?Symbol {
	var o: usize = 0;
	var i: usize = 0;

	// Avoid comptime optimization
	var ptr: []const u8 = @ptrCast( &symbolTable );
	while (
		ptr.len > 8
		and std.mem.order( u8, ptr[0..4], &[_]u8{ 0xde, 0xad, 0xbe, 0xef } ) != std.math.Order.eq
		and std.mem.order( u8, ptr[1..5], &[_]u8{ 0xde, 0xad, 0xbe, 0xef } ) != std.math.Order.eq
		and std.mem.order( u8, ptr[2..6], &[_]u8{ 0xde, 0xad, 0xbe, 0xef } ) != std.math.Order.eq
		and std.mem.order( u8, ptr[3..7], &[_]u8{ 0xde, 0xad, 0xbe, 0xef } ) != std.math.Order.eq
	) {
		var symbol = Symbol {
			.address = readAddress( ptr[0..4] ),
			.size    = readAddress( ptr[4..8] ),
			.name    = ptr[8..8]
		};

		o += 8;
		while ( ptr[o] != '\n' ) {
			o += 1;
			symbol.name.len += 1;
		}

		if ( i > 0 and address >= symbol.address and ( symbol.address + symbol.size ) >= address ) {
			return symbol;
		}

		o += 1;
		i += 1;

		ptr = ptr[o..];
		o = 0;
	}

	return null;
}

var inPanic: bool = false;
pub fn printStack() void {
	var si = std.debug.StackIterator.init( @returnAddress(), null );

	while ( si.next() ) |ra| {
		root.log.printUnsafe( "[0x{x:0>8}] {s}\n", .{
			@as( u32, @truncate( ra ) ),
			if ( getSymbol( ra ) ) |s| ( s.name ) else ( "<unknown>" )
		} );
	}
}

pub fn panic( msg: []const u8, trace: ?*std.builtin.StackTrace, retAddr: ?usize ) noreturn {
	x86.disableInterrupts();

	_ = retAddr;
	_ = trace;

	if ( inPanic ) {
		root.log.printUnsafe( "\n\n!!! Double panic detected\n{s}\n", .{ msg } );
		printStack();
		x86.out( u16, 0x0604, 0x2000 );
		x86.halt();
	}

	inPanic = true;

	tty.setColor( .Blue, .White );
	tty.setCursor( .Disabled );
	if ( @import( "./com.zig" ).ports[0] ) |com| {
		_ = com.write( "\x1b[44m\x1b[97m" );
	}
	root.log.printUnsafe( "!!! Kernel panic: {s}\n\nStack trace:\n", .{ msg } );
	printStack();

	// QEMU shutdown
	x86.out( u16, 0x0604, 0x2000 );
	x86.halt();
}

pub export fn isrPanic( state: *x86.State ) noreturn {
	var errbuf: [128:0]u8 = undefined;
	const msg = if ( state.intNum <= 31 and state.intNum < MSG_EXCEPTION.len ) (
		if ( state.intNum >= 10 and state.intNum <= 13 ) (
			std.fmt.bufPrintZ( &errbuf, "Unhandled exception {s} ({s}[{}])", .{
				MSG_EXCEPTION[state.intNum],
				switch ( state.errNum & 0b111 ) {
					0b000 => "GDT",
					0b001 => "EXT",
					0b100 => "LDT",
					0b010,
					0b110 => "IDT",
					else  => "???"
				},
				state.errNum >> 3
			} )
		) else if ( state.intNum == 14 ) (
			std.fmt.bufPrintZ( &errbuf, "Unhandled exception {s} ({}: {x:0>8})", .{
				MSG_EXCEPTION[state.intNum],
				state.errNum,
				asm volatile ( "movl %%cr2, %[out]" : [out] "=r" ( -> u32 ) )
			} )
		) else (
			std.fmt.bufPrintZ( &errbuf, "Unhandled exception {s} ({x}:{x})", .{ MSG_EXCEPTION[state.intNum], state.intNum, state.errNum } )
		)
	) else (
		std.fmt.bufPrintZ( &errbuf, "Unhandled interrupt {x}:{x}", .{ state.intNum, state.errNum } )
	);

	@panic( msg catch unreachable );
}
