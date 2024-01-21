const std = @import( "std" );
const root = @import( "root" );
const elf = @import( "./elf.zig" );
const mem = @import( "./mem.zig" );
const task = @import( "./task.zig" );
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

export const symbolTable: [64 * 1024]u8 align(4096) = .{ 0xde, 0xad, 0xbe, 0xef } ** ( 64 * 256 );

const Symbol = struct {
	address: usize,
	size: usize,
	name: []const u8
};

fn getSymbol( address: usize ) ?[]const u8 {
	var i: usize = 0;

	// Avoid comptime optimization
	var ptr: []const u8 = @ptrCast( &symbolTable );
	while (
		ptr.len > 8
		and !std.mem.eql( u8, ptr[0..4], &[_]u8{ 0xde, 0xad, 0xbe, 0xef } )
		and !std.mem.eql( u8, ptr[1..5], &[_]u8{ 0xde, 0xad, 0xbe, 0xef } )
		and !std.mem.eql( u8, ptr[2..6], &[_]u8{ 0xde, 0xad, 0xbe, 0xef } )
		and !std.mem.eql( u8, ptr[3..7], &[_]u8{ 0xde, 0xad, 0xbe, 0xef } )
	) {
		const symbol = Symbol {
			.address = @byteSwap( @as( *const align(1) u32, @ptrCast( &ptr[0] ) ).* ),
			.size    = @byteSwap( @as( *const align(1) u32, @ptrCast( &ptr[4] ) ).* ),
			.name    = std.mem.sliceTo( ptr[8..], '\n' )
		};

		if ( i > 0 and address >= symbol.address and ( symbol.address + symbol.size ) >= address ) {
			return symbol.name;
		}

		i += 1;
		ptr = ptr[( 9 + symbol.name.len )..];
	}

	return null;
}

inline fn printSymbol( addr: usize, di: *?elf.DwarfInfo, fallback: []const u8 ) void {
	if ( di.* ) |*i| {
		if ( i.printSymbol( root.log.writer(), root.kheap, addr ) catch false ) {
			return;
		}
	}

	root.log.printUnsafe( "{s}\n", .{ fallback } );
}

pub var earlyPanic: bool = true;
var inPanic: bool = false;
pub fn printStack( fp: usize ) void {
	var si: *[2]usize = @ptrFromInt( fp );

	var arena = std.heap.ArenaAllocator.init( root.kheap );
	const alloc = arena.allocator();
	defer arena.deinit();

	var kdi: ?elf.DwarfInfo = null;
	var tdi: ?elf.DwarfInfo = null;
	var kdiLoad = false;
	var tdiLoad = false;

	task.currentTask.kernelMode = true;

	while ( si[0] != 0 and si[1] != 0 ) : ( si = @ptrFromInt( si[0] ) ) {
		const ra = si[1];

		if ( ra >= mem.ADDR_KMAIN_OFFSET ) {
			if ( !earlyPanic and kdi == null and !kdiLoad ) {
				kdiLoad = true;
				kdi = @import( "./api/panic.zig" ).openDwarfInfo( "/kernel.dbg", alloc ) catch |err| _: {
					root.log.printUnsafe( "! Unable to retrieve kernel symbol information: {}\n", .{ err } );
					break :_ null;
				};
			}

			root.log.printUnsafe( "[0x{x:0>8}] ", .{ @as( u32, @truncate( ra ) ) } );
			printSymbol( @truncate( ra ), &kdi, getSymbol( ra ) orelse "<kernel:unknown>" );
		} else {
			if ( !earlyPanic and tdi == null and !tdiLoad and task.currentTask.bin != null ) {
				tdiLoad = true;
				tdi = @import( "./api/panic.zig" ).openDwarfInfo( task.currentTask.bin.?, alloc ) catch |err| _: {
					root.log.printUnsafe( "! Unable to retrieve task symbol information: {}\n", .{ err } );
					break :_ null;
				};
			}

			root.log.printUnsafe( "[0x{x:0>8}] ", .{ @as( u32, @truncate( ra ) ) } );
			if ( task.currentTask.bin ) |bin| {
				root.log.printUnsafe( "{s}:", .{ bin } );
			}

			printSymbol( @truncate( ra ), &tdi, "<task:unknown>" );
		}

		if (
			si[0] == 0
			or si[1] == 0
			or si[0] == task.currentTask.stackBreak
			or !std.mem.isAligned( si[0], @alignOf( usize ) )
			or !(
				si[0] > @intFromPtr( si )
				or ( @intFromPtr( si ) > mem.ADDR_KMAIN_OFFSET and si[0] < mem.ADDR_KMAIN_OFFSET )
			)
			or ( si[0] > task.currentTask.programBreak and si[0] < mem.ADDR_KMAIN_OFFSET - mem.PAGE_SIZE )
			or ( si[1] > task.currentTask.programBreak and si[1] < mem.ADDR_KMAIN_OFFSET )
		) {
			break;
		}
	}
}

var panicState: ?*x86.State = null;
pub fn panic( msg: []const u8, trace: ?*std.builtin.StackTrace, retAddr: ?usize ) noreturn {
	x86.disableInterrupts();

	_ = retAddr;
	_ = trace;

	if ( inPanic ) {
		root.log.printUnsafe( "\n\n!!! Double panic detected\n{s}\n", .{ msg } );
		// printStack( @frameAddress() );
		root.log.writeUnsafe( "\x1b[0m" ++ "\x1b[?25h" );
		x86.out( u16, 0x0604, 0x2000 );
		x86.halt();
	}

	inPanic = true;
	@import( "./syscall.zig" ).enableStrace = false;

	root.log.printUnsafe( "\x1b[44m" ++ "\x1b[97m" ++ "\x1b[?25l" ++ "\n!!! Kernel panic: {s}\n\nStack trace:\n", .{ msg } );
	if ( panicState ) |s| {
		const tmp = [2]usize{ s.ebp, s.eip };
		printStack( @intFromPtr( &tmp ) );
	} else {
		printStack( @frameAddress() );
	}

	// QEMU shutdown
	root.log.writeUnsafe( "\x1b[0m" ++ "\x1b[?25h" );
	x86.out( u16, 0x0604, 0x2000 );
	x86.halt();
}

pub export fn isrPanic( state: *x86.State ) noreturn {
	var errbuf: [128:0]u8 = undefined;
	panicState = state;

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
