const std = @import( "std" );
const irq = @import( "./irq.zig" );
const vfs = @import( "./vfs.zig" );
const x86 = @import( "./x86.zig" );
const RingBuffer = @import( "./util/ringBuffer.zig" ).RingBuffer;
const Stream = @import( "./util/stream.zig" ).Stream;

const Scancode = struct {
	const Released:   u8 = 0x80;
	const Extended:   u8 = 0xe0;

	const Enter:      u8 = 0x1c;

	const ShiftLeft:  u8 = 0x2a;
	const ShiftRight: u8 = 0x36;
	const CtrlLeft:   u8 = 0x1d;
	const AltLeft:    u8 = 0x38;
};

const ScancodeExt = struct {
	pub const CtrlRight: u8 = 0x1d;
	pub const AltRight:  u8 = 0x38;
};

const keymap = [_]u8 {
	0,  // 0x00: null
	27, // 0x01: Escape
	'1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=',
	'\x08', // 0x0e: Backspace
	'\t',
	'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']',
	'\n',
	0, // 0x1d: Left Control
	'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`',
	0, // 0x2a: Left Shift
	'\\', 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/',
	0, // 0x36: Right Shift
	'*', // keypad
	0, // Left Alt
	' ',
	0, // CapsLock
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // F1 - F10
	0, // NumLock
	0, // ScrollLock

	// keypad
	'7', '8', '9', '-',
	'4', '5', '6', '+',
	'1', '2', '3', '0', '.',

	0, 0, 0, // gap
	0, 0,    // F11 - F12
	0, 0, 0, // gap
};

const keymapShift = [keymap.len]u8 {
	0,  // 0x00: null
	27, // 0x01: Escape
	'!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+',
	'\x08', // 0x0e: Backspace
	'\t',
	'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}',
	'\n',
	0, // 0x1d: Left Control
	'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~',
	0, // 0x2a: Left Shift
	'|', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?',
	0, // 0x36: Right Shift
	'*', // keypad
	0, // Left Alt
	' ',
	0, // CapsLock
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // F1 - F10
	0, // NumLock
	0, // ScrollLock

	// keypad
	'7', '8', '9', '-',
	'4', '5', '6', '+',
	'1', '2', '3', '0', '.',

	0, 0, 0, // gap
	0, 0,    // F11 - F12
	0, 0, 0, // gap
};

const State = struct {
	extendedMode: bool = false,

	shiftLeft: bool    = false,
	shiftRight: bool   = false,
	ctrlLeft: bool     = false,
	ctrlRight: bool    = false,
	altLeft: bool      = false,
	altRight: bool     = false,

	buffer: RingBuffer( u8, 64 ) = .{},
};
var state = State {};
var fsNode: vfs.Node = undefined;

fn onKey( _: *x86.State ) void {
	var code = x86.in( u8, 0x60 );

	if ( state.extendedMode ) {
		state.extendedMode = false;

		inline for ( .{
			.{ ScancodeExt.CtrlRight, &state.ctrlRight },
			.{ ScancodeExt.AltRight , &state.altRight  },
		} ) |modifier| {
			if ( code == modifier[0] or ( code ^ Scancode.Released ) == modifier[0] ) {
				modifier[1].* = ( code & Scancode.Released ) == 0;
				return;
			}
		}
	} else if ( code == Scancode.Extended ) {
		state.extendedMode = true;
	} else {
		inline for ( .{
			.{ Scancode.ShiftLeft , &state.shiftLeft  },
			.{ Scancode.ShiftRight, &state.shiftRight },
			.{ Scancode.CtrlLeft  , &state.ctrlLeft   },
			.{ Scancode.AltLeft   , &state.altLeft    },
		} ) |modifier| {
			if ( code == modifier[0] or ( code ^ Scancode.Released ) == modifier[0] ) {
				modifier[1].* = ( code & Scancode.Released ) == 0;
				return;
			}
		}

		if (
			( code & Scancode.Released ) == 0
			and code < keymap.len
		) {
			const char = ( if ( state.shiftLeft or state.shiftRight ) ( keymapShift ) else ( keymap ) )[code];
			if ( char != 0 ) {
				_ = state.buffer.push( char );
				fsNode.signal( .{ .read = true } );
			}
		}
	}
}

pub fn init() void {
	irq.set( irq.Interrupt.Keyboard, onKey );
	fsNode.init( 1, "kbd0", .CharDevice, undefined, .{ .read = &fsRead } );
	vfs.devNode.link( &fsNode ) catch unreachable;
}

pub fn read( buf: []u8, fd: ?*vfs.FileDescriptor ) usize {
	for ( 0..buf.len ) |i| {
		while ( state.buffer.isEmpty() ) {
			fsNode.signal( .{ .read = false } );

			if ( i > 0 ) {
				return i;
			}

			if ( fd ) |wfd| {
				@import( "./task.zig" ).currentTask.park(
					.{ .fd = .{ .ptr = wfd, .status = .{ .read = true } } }
				);
			} else {
				asm volatile ( "hlt" );
			}
		}

		buf[i] = state.buffer.pop().?;
	}

	if ( state.buffer.isEmpty() ) {
		fsNode.signal( .{ .read = false } );
	}

	return buf.len;
}

pub fn fsRead( _: ?*vfs.Node, fd: *vfs.FileDescriptor, buf: []u8 ) u32 {
	return read( buf, fd );
}

pub fn streamRead( _: ?*anyopaque, buf: []u8 ) error{}!usize {
	return read( buf, null );
}

pub fn reader() std.io.Reader( ?*anyopaque, error{}, streamRead ) {
	return .{ .context = null };
}

pub fn stream() Stream {
	return .{
		.context = null,
		.vtable = .{
			.read = read
		}
	};
}
