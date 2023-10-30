const std = @import( "std" );

const BUFSIZE = 80;

fn shell( dev: [:0]const u8 ) void {
	const SYSCALL_ERR: usize = @bitCast( @as( isize, -1 ) );

	var fd: i32 = @bitCast( std.os.linux.open( dev.ptr, std.os.linux.O.RDWR, 0 ) );
	_ = std.os.linux.write( fd, "> ", 2 );

	var buf: [BUFSIZE]u8 = .{ 0 } ** BUFSIZE;
	var p: usize = 0;
	var s: usize = std.os.linux.read( fd, &buf, 1 );
	while ( s != SYSCALL_ERR ) : ( s = std.os.linux.read( fd, @ptrCast( buf[p..] ), 1 ) ) {
		if ( s > 0 ) {
			if ( buf[p] == 0x08 ) { // \b
				_ = std.os.linux.write( fd, "\x08 \x08", 3 );
				p -|= 1;
			} else if ( buf[p] == '\n' ) {
				_ = std.os.linux.write( fd, @ptrCast( buf[p..] ), 1 );

				if ( p > 0 ) {
					process( fd, std.mem.trim( u8, buf[0..p], " " ) );
					_ = std.os.linux.write( fd, "\n> ", 3 );
				}

				p = 0;
			} else {
				_ = std.os.linux.write( fd, @ptrCast( buf[p..] ), 1 );
				p += s;
			}

			if ( p == BUFSIZE ) {
				_ = std.os.linux.write( fd, "\n> ", 3 );
				p = 0;
			}
		}
	}
}

fn process( fd: i32, cmd: []const u8 ) void {
	if ( std.mem.eql( u8, cmd, "exit" ) ) {
		_ = std.os.linux.write( fd, "bye!\n", 5 );
		std.os.linux.exit( 0 );
	} else {
		_ = std.os.linux.write( fd, cmd.ptr, cmd.len );
	}
}

pub fn task( comptime dev: [:0]const u8 ) fn() void {
	return struct {
		fn stub() void {
			shell( dev );
		}
	}.stub;
}
