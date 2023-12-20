const std = @import( "std" );
const gdt = @import( "./gdt.zig" );
const mem = @import( "./mem.zig" );
const vga = @import( "./vga.zig" );
const vfs = @import( "./vfs.zig" );
const Stream = @import( "./util/stream.zig" ).Stream;

pub const Color = enum(u4) {
	Black        = 0,
	Blue         = 1,
	Green        = 2,
	Cyan         = 3,
	Red          = 4,
	Magenta      = 5,
	Brown        = 6,
	LightGrey    = 7,
	DarkGrey     = 8,
	LightBlue    = 9,
	LightGreen   = 10,
	LightCyan    = 11,
	LightRed     = 12,
	LightMagenta = 13,
	LightBrown   = 14,
	White        = 15
};

pub const Cursor = enum( u8 ) {
	Full     = 0x00,
	Thin     = 0x0d,
	Disabled = 0x20
};

var buf: []volatile u16 = @as( [*]volatile u16, @ptrFromInt( mem.ADDR_KMAIN_OFFSET + 0xb8000 ) )[0..( cols * rows )];
var col: u16 = 0;
const cols: u16 = 80;
var row: u16 = 0;
const rows: u16 = 25;
var color: u16 = 0x0700;
var softLF: bool = false;
var fsNode: vfs.Node = undefined;

pub fn init() void {
	// gdt.setPort( vga.Register.ControlSelect, true );
	// gdt.setPort( vga.Register.ControlData, true );
	vga.setControlReg( vga.ControlRegister.CursorStart, @intFromEnum( Cursor.Thin ) );
	clear();

	fsNode.init( 1, .CharDevice, undefined, .{
		.write = &writeFs,
		.ioctl = &ioctl
	} );
	vfs.devNode.link( &fsNode, "tty0" ) catch unreachable;
}

pub fn clear() void {
	for ( 0..( rows * cols ) ) |i| {
		buf[i] = color | ' ';
	}

	col = 0;
	row = 0;
	moveCursor( col, row );
}

fn putc( c: u8 ) void {
	switch ( c ) {
		0x08 => { // \b
			if ( col > 0 ) {
				col -= 1;
				const i: usize = ( cols * row ) + col;
				buf[i] = color | ' ';
			}
		},
		'\n' => {
			if ( softLF ) {
				softLF = true;
			} else {
				col = 0;
				row += 1;
			}
		},
		'\t' => {
			col += 4 - ( col % 4 );
		},
		else => {
			const i: usize = ( cols * row ) + col;
			buf[i] = color | c;
			col += 1;
		}
	}

	if ( col >= cols ) {
		softLF = c != '\n';
		col = 0;
		row += 1;
	} else {
		softLF = false;
	}

	if ( row >= rows ) {
		scroll();
		col = 0;
		row -= 1;
	}
}

fn scroll() void {
	for ( 0..( ( rows - 1 ) * cols ) ) |i| {
		buf[i] = buf[i + cols];
	}

	@memset( buf[( ( rows - 1 ) * cols )..( rows * cols )], color | ' ' );
}

pub fn setColor( bg: Color, fg: Color ) void {
	color = @as( u16, @intFromEnum( bg ) ) << 12 | @as( u16, @intFromEnum( fg ) ) << 8;
}

pub fn setCursor( style: Cursor ) void {
	vga.setControlReg( vga.ControlRegister.CursorStart, @intFromEnum( style ) );
}

fn moveCursor( ncol: u16, nrow: u16 ) void {
	const pos: u16 = nrow * cols + ncol;
	vga.setControlReg( vga.ControlRegister.CursorLocLow, @truncate( pos ) );
	vga.setControlReg( vga.ControlRegister.CursorLocHigh, @truncate( pos >> 8 ) );
}

pub fn write( _: ?*anyopaque, msg: []const u8 ) error{}!usize {
	var i: usize = 0;
	while ( i < msg.len ) : ( i += 1 ) {
		if ( msg[i] == 0 ) {
			break;
		} else if ( std.mem.startsWith( u8, msg[i..], "\x1b[" ) ) {
			i += 2;
			if ( std.mem.startsWith( u8, msg[i..], "2K" ) ) {
				if ( softLF ) {
					row -= 1;
				}

				for ( ( cols * row )..( cols * ( row + 1 ) ) ) |j| {
					buf[j] = color | ' ';
				}

				if ( softLF ) {
					row += 1;
				}

				i += 1;
			} else if ( std.mem.startsWith( u8, msg[i..], "1G" ) ) {
				col = 0;
				if ( softLF ) {
					row -= 1;
				}

				i += 1;
			} else if ( std.mem.startsWith( u8, msg[i..], "0m" ) ) {
				color = 0x0700;
				i += 1;
			} else if ( std.mem.startsWith( u8, msg[i..], "7m" ) ) {
				color = ( ( color << 4 ) & 0xf000 ) | ( ( color >> 4 ) & 0x0f00 );
				i += 1;
			} else if ( std.mem.startsWith( u8, msg[i..], "44m" ) ) {
				color = ( color & 0x0f00 ) | ( @as( u16, @intFromEnum( Color.Blue ) ) << 12 );
				i += 2;
			} else if ( std.mem.startsWith( u8, msg[i..], "97m" ) ) {
				color = ( color & 0xf000 ) | ( @as( u16, @intFromEnum( Color.White ) ) << 8 );
				i += 2;
			} else if ( std.mem.startsWith( u8, msg[i..], "?25h" ) ) {
				setCursor( .Thin );
				i += 3;
			} else if ( std.mem.startsWith( u8, msg[i..], "?25l" ) ) {
				setCursor( .Disabled );
				i += 3;
			}
		} else {
			putc( msg[i] );
		}
	}

	moveCursor( col, row );
	return i;
}

fn writeFs( _: *vfs.Node, _: *vfs.FileDescriptor, msg: []const u8 ) u32 {
	return write( null, msg ) catch unreachable;
}

pub fn print( comptime fmt: []const u8, args: anytype ) !void {
	try std.fmt.format( std.io.Writer( ?*anyopaque, error{}, write ) { .context = null }, fmt, args );
}

pub fn stream() Stream {
	return .{
		.context = null,
		.vtable = .{
			.write = write
		}
	};
}

fn ioctl( _: *vfs.Node, _: *vfs.FileDescriptor, cmd: u32, arg: usize ) @import( "./task.zig" ).Error!i32 {
	if ( cmd == std.os.linux.T.IOCGWINSZ ) {
		const ws: *std.os.linux.winsize = @ptrFromInt( arg );
		ws.ws_row = rows;
		ws.ws_col = cols;
		ws.ws_xpixel = 0;
		ws.ws_ypixel = 0;
		return 0;
	}

	return error.BadFileDescriptor;
}
