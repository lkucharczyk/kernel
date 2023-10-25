const std = @import( "std" );
const vga = @import( "./vga.zig" );
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

var buf: [*]volatile u16 = @ptrFromInt( 0xc00b_8000 );
var col: u16 = 0;
const cols: u16 = 80;
var row: u16 = 0;
const rows: u16 = 25;
var color: u16 = 0x0700;
var softLF: bool = false;

pub fn init() void {
	vga.setControlReg( vga.ControlRegister.CursorStart, @intFromEnum( Cursor.Thin ) );
	clear();
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
	for ( msg ) |c| {
		if ( c == 0 ) {
		 	break;
		}

		putc( c );
	}

	moveCursor( col, row );
	return msg.len;
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
