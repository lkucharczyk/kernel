const std = @import( "std" );

const linux = std.os.linux;

const BUFSIZE = 80;

fn write( fd: i32, buf: []const u8 ) void {
	_ = linux.write( fd, buf.ptr, buf.len );
}

fn shell( dev: [:0]const u8 ) void {
	const SYSCALL_ERR: usize = @bitCast( @as( isize, -1 ) );

	var fd: i32 = @bitCast( linux.open( dev.ptr, std.os.linux.O.RDWR, 0 ) );
	write( fd, "> " );

	var buf: [BUFSIZE]u8 = .{ 0 } ** BUFSIZE;
	var p: usize = 0;
	var s: usize = linux.read( fd, &buf, 1 );
	while ( s != SYSCALL_ERR ) : ( s = linux.read( fd, @ptrCast( buf[p..] ), 1 ) ) {
		if ( s > 0 ) {
			if ( buf[p] == 0x08 ) { // \b
				p -|= 1;
			} else if ( buf[p] == '\n' ) {
				write( fd, "\n" );

				if ( p > 0 ) {
					process( fd, std.mem.trim( u8, buf[0..p], " " ) );
				}

				p = 0;
			} else if ( std.ascii.isPrint( buf[p] ) ) {
				p += s;
			}

			if ( p == BUFSIZE ) {
				p -= 1;
			}

			// clear line + move to start
			write( fd, "\x1b[2K\x1b[1G> " );
			if ( p > 0 ) {
				write( fd, @ptrCast( buf[0..p] ) );
			}
		}
	}
}

fn process( fd: i32, cmd: []const u8 ) void {
	var iter = std.mem.tokenizeScalar( u8, cmd, ' ' );

	if ( iter.next() ) |cmd0| {
		if ( std.mem.eql( u8, cmd0, "exit" ) ) {
			write( fd, "bye!\n" );
			linux.exit( 0 );
		} else if ( std.mem.eql( u8, cmd0, "help" ) ) {
			var cmd1 = iter.next() orelse "";
			if ( std.mem.eql( u8, cmd1, "sendudp" ) ) {
				write( fd, "sendudp [ipv4 address] [port] [data...]\n" );
			} else {
				write( fd, "commands: sendudp, exit\n" );
			}
		} else if ( std.mem.eql( u8, cmd0, "sendudp" ) ) {
			var dst = std.net.Ip4Address.parse(
				iter.next() orelse return,
				std.fmt.parseInt( u16, iter.next() orelse return, 0 ) catch return
			) catch return;
			var sock: i32 = @bitCast( linux.socket( linux.PF.INET, linux.SOCK.DGRAM, linux.IPPROTO.UDP ) );
			var buf = iter.rest();

			_ = linux.sendto( sock, buf.ptr, buf.len, 0, @ptrCast( &dst.sa ), @sizeOf( linux.sockaddr.in ) );
			_ = linux.close( sock );
		}
	}
}

pub fn task( comptime dev: [:0]const u8 ) fn() void {
	return struct {
		fn stub() void {
			shell( dev );
		}
	}.stub;
}
