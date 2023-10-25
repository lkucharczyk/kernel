const std = @import( "std" );
const irq = @import( "./irq.zig" );
const x86 = @import( "./x86.zig" );
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
	0,  // null
	27, // Escape
	'1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=',
	'\x08', // Backspace
	'\t',
	'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']',
	'\n',
    0, // Left Control
	'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`',
	0, // Left Shift
	'\\', 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/',
	0, // Right Shift
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

	buffer: ?u8        = null,
};
var state = State {};

fn onKey( _: *x86.State ) void {
	var code = x86.in( u8, 0x60 );

	if ( state.extendedMode ) {
		state.extendedMode = false;

		inline for ( .{
			.{ ScancodeExt.CtrlRight, &state.ctrlRight },
			.{ ScancodeExt.AltRight , &state.altRight  },
		} ) |modifier| {
			if ( ( code ^ Scancode.Released ) == modifier[0] ) {
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
			if ( ( code ^ Scancode.Released ) == modifier[0] ) {
				modifier[1].* = ( code & Scancode.Released ) == 0;
				return;
			}
		}

		if (
			( code & Scancode.Released ) == 0
			and code < keymap.len
		) {
			const char = keymap[code];
			if ( char != 0 ) {
				if ( ( state.shiftLeft or state.shiftRight ) and char >= 'a' and char <= 'z' ) {
					state.buffer = char - 'a' + 'A';
				} else {
					state.buffer = char;
				}
			}
		} else if ( ( code & Scancode.Released ) > 0 ) {
			state.buffer = null;
		}
	}
}

pub fn init() void {
	irq.set( irq.Interrupt.Keyboard, onKey );
}

pub fn read( _: ?*anyopaque, buf: []u8 ) error{}!usize {
	var i: usize = 0;
	while ( i < buf.len ) {
		asm volatile ( "hlt" );

		if ( state.buffer ) |c| {
			buf[i] = c;
			state.buffer = null;
			i += 1;
		}
	}

	return i;
}

pub fn reader() std.io.Reader( ?*anyopaque, error{}, read ) {
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
