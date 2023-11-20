const std = @import( "std" );
const Errno = @import( "./task.zig" ).Errno;

pub usingnamespace @import( "./api/import.zig" );

const OsError = error {
	SyscallError
};

fn osRead( fd: i32, buf: []u8 ) OsError!usize {
	return h( std.os.system.read( fd, buf.ptr, buf.len ) );
}

fn osWrite( fd: i32, buf: []const u8 ) OsError!usize {
	return h( std.os.system.write( fd, buf.ptr, buf.len ) );
}

const stdin = std.io.Reader( i32, OsError, osRead ) { .context = 0 };
const stdout = std.io.Writer( i32, anyerror, osWrite ) { .context = 1 };
const stderr = std.io.Writer( i32, anyerror, osWrite ) { .context = 2 };

const linux = std.os.linux;
const system = std.os.system;

const BUFSIZE = 79;

inline fn write( buf: []const u8 ) void {
	_ = stdout.write( buf ) catch unreachable;
}

inline fn print( comptime fmt: []const u8, args: anytype ) void {
	std.fmt.format( stdout, fmt, args ) catch unreachable;
}

pub fn main() anyerror!void {
	const SYSCALL_ERR: usize = @bitCast( @as( isize, -1 ) );

	if ( std.os.argv.len >= 2 ) {
		_ = try h( system.close( 0 ) );
		_ = try h( system.open( std.os.argv[1], std.os.linux.O.RDONLY, 0 ) );
	}
	if ( std.os.argv.len >= 3 ) {
		_ = try h( system.close( 1 ) );
		_ = try h( system.open( std.os.argv[2], std.os.linux.O.WRONLY, 0 ) );
		_ = try h( system.close( 2 ) );
		_ = try h( system.open( std.os.argv[2], std.os.linux.O.WRONLY, 0 ) );
	}
	write( "> " );

	var buf: [BUFSIZE]u8 = .{ 0 } ** BUFSIZE;
	var p: usize = 0;
	var s: usize = try stdin.read( &buf );

	while ( s != SYSCALL_ERR ) : ( s = try stdin.read( buf[p..] ) ) {
		if ( s > 0 ) {
			if ( p > 0 and buf[p] == 0x03 ) { // ctrl-c
				write( "\x1b[7m" ++ "^C" ++ "\x1b[0m" ++ "\n" );
				p = 0;
			} else if ( buf[p] == 0x08 ) { // \b
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

fn h( retval: usize ) OsError!usize {
	const i: isize = @bitCast( retval );
	if ( i <= -1 and i >= -1024 ) {
		print( "error: {}\n", .{ @as( Errno, @enumFromInt( -i ) ) } );
		return error.SyscallError;
	}

	return retval;
}

fn process( cmd: []const u8 ) OsError!void {
	var iter = std.mem.tokenizeScalar( u8, cmd, ' ' );

	if ( iter.next() ) |cmd0| {
		if ( std.mem.eql( u8, cmd0, "exit" ) ) {
			write( "bye!\n" );
			linux.exit( 0 );
		} else if ( std.mem.eql( u8, cmd0, "kpanic" ) ) {
			asm volatile ( "int $0x03" );
		} else if ( std.mem.eql( u8, cmd0, "panic" ) ) {
			@panic( "Manual panic" );
		} else if ( std.mem.eql( u8, cmd0, "help" ) ) {
			var cmd1 = iter.next() orelse "";
			if ( std.mem.eql( u8, cmd1, "recvudp" ) ) {
				write( "recvudp [port]\n" );
			} else if ( std.mem.eql( u8, cmd1, "recvudpd" ) ) {
				write( "recvudpd [ports...]\n" );
			} else if ( std.mem.eql( u8, cmd1, "sendudp" ) ) {
				write( "sendudp [ipv4 address] [port] [data...]\n" );
			} else {
				write( "commands: recvudp, recvudpd, sendudp, exit, kpanic, panic\n" );
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
							if ( try h( linux.read( 0, &buf, 1 ) ) > 0 and buf[0] == 0x03 ) {
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
