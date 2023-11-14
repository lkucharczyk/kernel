const std = @import( "std" );
const Errno = @import( "./task.zig" ).Errno;

const linux = std.os.linux;

const BUFSIZE = 79;

inline fn write( buf: []const u8 ) void {
	_ = linux.write( 1, buf.ptr, buf.len );
}

inline fn print( comptime fmt: []const u8, args: anytype ) void {
	std.fmt.format( std.io.Writer( i32, anyerror, writeStream ) { .context = 1 }, fmt, args ) catch unreachable;
}

fn writeStream( fd: i32, buf: []const u8 ) anyerror!usize {
	return linux.write( fd, buf.ptr, buf.len );
}

fn shell( devIn: [:0]const u8, devOut: [:0]const u8 ) void {
	const SYSCALL_ERR: usize = @bitCast( @as( isize, -1 ) );

	_ = linux.close( 0 );
	_ = linux.open( devIn.ptr, std.os.linux.O.RDONLY, 0 );
	_ = linux.close( 1 );
	_ = linux.open( devOut.ptr, std.os.linux.O.WRONLY, 0 );
	_ = linux.close( 2 );
	_ = linux.open( devOut.ptr, std.os.linux.O.WRONLY, 0 );
	write( "> " );

	var buf: [BUFSIZE]u8 = .{ 0 } ** BUFSIZE;
	var p: usize = 0;
	var s: usize = linux.read( 0, &buf, 1 );
	while ( s != SYSCALL_ERR ) : ( s = linux.read( 0, @ptrCast( buf[p..] ), buf.len - p ) ) {
		if ( s > 0 ) {
			if ( buf[p] == 0x08 ) { // \b
				p -|= 1;
			} else if ( buf[p] == '\n' ) {
				write( "\n" );

				if ( p > 0 ) {
					process( std.mem.trim( u8, buf[0..p], " " ) ) catch {};
				}

				p = 0;
			} else if ( std.ascii.isPrint( buf[p] ) ) {
				p += s;
			}

			if ( p == buf.len ) {
				p -= 1;
			}

			// clear line + move to start
			write( "\x1b[2K\x1b[1G> " );
			if ( p > 0 ) {
				write( @ptrCast( buf[0..p] ) );
			}
		}
	}
}

fn h( retval: usize ) error{ SyscallError }!usize {
	const i: isize = @bitCast( retval );
	if ( i <= -1 and i >= -1024 ) {
		print( "error: {}\n", .{ @as( Errno, @enumFromInt( -i ) ) } );
		return error.SyscallError;
	}

	return retval;
}

fn process( cmd: []const u8 ) error{ SyscallError }!void {
	var iter = std.mem.tokenizeScalar( u8, cmd, ' ' );

	if ( iter.next() ) |cmd0| {
		if ( std.mem.eql( u8, cmd0, "exit" ) ) {
			write( "bye!\n" );
			linux.exit( 0 );
		} else if ( std.mem.eql( u8, cmd0, "help" ) ) {
			var cmd1 = iter.next() orelse "";
			if ( std.mem.eql( u8, cmd1, "recvudp" ) ) {
				write( "recvudp [port]\n" );
			} else if ( std.mem.eql( u8, cmd1, "recvudpd" ) ) {
				write( "recvudpd [ports...]\n" );
			} else if ( std.mem.eql( u8, cmd1, "sendudp" ) ) {
				write( "sendudp [ipv4 address] [port] [data...]\n" );
			} else {
				write( "commands: recvudp, recvudpd, sendudp, exit\n" );
			}
		} else if ( std.mem.eql( u8, cmd0, "recvudp" ) ) {
			const sock: i32 = @bitCast( try h( linux.socket( linux.PF.INET, linux.SOCK.DGRAM, linux.IPPROTO.UDP ) ) );
			defer _ = linux.close( sock );

			var src: @import( "./net/sockaddr.zig" ).Ipv4 = undefined;
			var srclen: u32 = @sizeOf( @TypeOf( src ) );
			var buf: [0x600]u8 = undefined;

			const addr = linux.sockaddr.in {
				.addr = 0,
				.port = @byteSwap( std.fmt.parseInt( u16, iter.next() orelse return, 0 ) catch return )
			};
			_ = try h( linux.bind( sock, @ptrCast( &addr ), @sizeOf( linux.sockaddr.in ) ) );

			const len = try h( linux.recvfrom( sock, &buf, buf.len, 0, @ptrCast( &src ), &srclen ) );
			print( "{}: \"{s}\"\n", .{ src, std.mem.trim( u8, buf[0..len], "\n\x00" ) } );
		} else if ( std.mem.eql( u8, cmd0, "recvudpd" ) ) {
			var fds =
				[1]linux.pollfd { .{ .fd = 0, .events = linux.POLL.IN, .revents = 0 } }
				++ ( [_]linux.pollfd { .{ .fd = -1, .events = linux.POLL.IN, .revents = 0 } } ** 15 );
			var fdlen: usize = 1;

			defer for ( 1..fdlen ) |i| {
				_ = linux.close( fds[i].fd );
			};

			for ( 1..fds.len ) |i| {
				const addr = linux.sockaddr.in {
					.addr = 0,
					.port = @byteSwap( std.fmt.parseInt( u16, iter.next() orelse break, 0 ) catch return )
				};

				fdlen += 1;
				fds[i].fd = @bitCast( try h( linux.socket( linux.PF.INET, linux.SOCK.DGRAM, linux.IPPROTO.UDP ) ) );
				_ = try h( linux.bind( fds[i].fd, @ptrCast( &addr ), @sizeOf( linux.sockaddr.in ) ) );
			}

			var src: @import( "./net/sockaddr.zig" ).Ipv4 = undefined;
			var srclen: u32 = @sizeOf( @TypeOf( src ) );
			var buf: [0x600]u8 = undefined;

			var out: usize = linux.poll( &fds, fdlen, -1 );
			while ( out > 0 ) : ( out = linux.poll( &fds, fdlen, -1 ) ) {
				for ( fds ) |fd| {
					if ( ( fd.revents & linux.POLL.IN ) > 0 ) {
						if ( fd.fd == 0 ) {
							if ( try h( linux.read( 0, &buf, 1 ) ) > 0 and buf[0] == 'x' ) {
								return;
							}
						} else {
							const len = try h( linux.recvfrom( fd.fd, &buf, buf.len, 0, @ptrCast( &src ), &srclen ) );
							print( "{}: \"{s}\"\n", .{ src, std.mem.trim( u8, buf[0..len], "\n\x00" ) } );
						}
					}
				}
			}
		} else if ( std.mem.eql( u8, cmd0, "sendudp" ) ) {
			var dst = std.net.Ip4Address.parse(
				iter.next() orelse return,
				std.fmt.parseInt( u16, iter.next() orelse return, 0 ) catch return
			) catch return;
			var sock: i32 = @bitCast( try h( linux.socket( linux.PF.INET, linux.SOCK.DGRAM, linux.IPPROTO.UDP ) ) );
			var buf = iter.rest();

			_ = try h( linux.sendto( sock, buf.ptr, buf.len, 0, @ptrCast( &dst.sa ), @sizeOf( linux.sockaddr.in ) ) );
			_ = try h( linux.close( sock ) );
		}
	}
}

pub fn task( comptime devIn: [:0]const u8, comptime devOut: [:0]const u8 ) fn() void {
	return struct {
		fn stub() void {
			shell( devIn, devOut );
		}
	}.stub;
}
