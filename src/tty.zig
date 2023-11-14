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

	fsNode.init( 1, "tty0", .CharDevice, undefined, .{ .write = &writeFs }  );
	vfs.devNode.link( &fsNode ) catch unreachable;
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
		} else if ( msg[i] == 0x1b ) {
			i += 1;
			if ( std.mem.eql( u8, msg[i..( i + 3 )], "[2K" ) ) {
				if ( softLF ) {
					row -= 1;
				}

				for ( ( cols * row )..( cols * ( row + 1 ) ) ) |j| {
					buf[j] = color | ' ';
				}

				if ( softLF ) {
					row += 1;
				}

				i += 2;
			} else if ( std.mem.eql( u8, msg[i..( i + 3 )], "[1G" ) ) {
				col = 0;
				if ( softLF ) {
					row -= 1;
				}

				i += 2;
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
