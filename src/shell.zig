const std = @import( "std" );
const net = @import( "./net.zig" );
const Errno = @import( "./task.zig" ).Errno;

pub usingnamespace @import( "./api/import.zig" );

const OsError = error {
	OutOfMemory,
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

var gpa = std.heap.GeneralPurposeAllocator( .{ .safety = false } ) {};
const alloc: std.mem.Allocator = gpa.allocator();

pub fn main() anyerror!void {
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
	print( "argv: [{}]{s}\n> ", .{ std.os.argv.len,  std.os.argv } );

	var inbuf: [BUFSIZE]u8 = .{ 0 } ** BUFSIZE;
	var cmdbuf: [BUFSIZE]u8 = .{ 0 } ** BUFSIZE;
	var p: usize = 0;
	var s: usize = try stdin.read( &inbuf );

	while ( s != 0 ) : ( s = try stdin.read( &inbuf ) ) {
		for ( inbuf ) |c| {
			if ( p > 0 and c == 0x03 ) { // ctrl-c
				write( "\x1b[7m" ++ "^C" ++ "\x1b[0m" ++ "\n" );
				p = 0;
			} else if ( p == 0 and c == 0x04 ) { // ctrl-d
				write( "\x1b[7m" ++ "^D" ++ "\x1b[0m" ++ "\n" );
				process( "exit" ) catch {};
			} else if ( c == 0x08 ) { // \b
				p -|= 1;
			} else if ( c == '\n' ) {
				// clear line + move to start
				write( "\x1b[2K\x1b[1G> " );
				if ( p > 0 ) {
					write( @ptrCast( cmdbuf[0..p] ) );
				}
				write( "\n" );

				if ( p > 0 ) {
					process( std.mem.trim( u8, cmdbuf[0..p], " " ) ) catch {};
				}

				p = 0;
			} else if ( std.ascii.isPrint( c ) ) {
				cmdbuf[p] = c;
				p += 1;
			}

			if ( p == cmdbuf.len ) {
				p -= 1;
			}
		}

		// clear line + move to start
		write( "\x1b[2K\x1b[1G> " );
		if ( p > 0 ) {
			write( @ptrCast( cmdbuf[0..p] ) );
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

pub const BINARIES_SBASE = [_][:0]const u8{
	"basename", "cal", "cat", "chgrp", "chmod", "chown", "chroot", "cksum", "cmp", "cols", "comm",
	"cp", "cron", "cut", "date", "dd", "dirname", "du", "echo", "ed", "env", "expand", "expr",
	"false", "find", "flock", "fold", "getconf", "grep", "head", "hostname", "join", "kill",
	"link", "ln", "logger", "logname", "ls", "md5sum", "mkdir", "mkfifo", "mknod", "mktemp", "mv",
	"nice", "nl", "nohup", "od", "paste", "pathchk", "printenv", "printf", "pwd", "readlink",
	"renice", "rev", "rm", "rmdir", "sed", "seq", "setsid", "sha1sum", "sha224sum", "sha256sum",
	"sha384sum", "sha512-224sum", "sha512-256sum", "sha512sum", "sleep", "sort", "split", "sponge",
	"strings", "sync", "tail", "tar", "tee", "test", "tftp", "time", "touch", "tr", "true",
	"tsort", "tty", "uname", "unexpand", "uniq", "unlink", "uudecode", "uuencode", "wc", "which",
	"whoami", "xargs", "xinstall", "yes"
};

const BINARIES = [_][:0]const u8{ "/bin/sbase-box", "/bin/shell" };

fn extractBin( name: []const u8 ) ?[:0]const u8 {
	for ( &BINARIES ) |bin| {
		if ( std.mem.eql( u8, name, bin[5..] ) ) {
			return bin;
		}
	}

	for ( &BINARIES_SBASE ) |bin| {
		if ( std.mem.eql( u8, name, bin ) ) {
			return "/bin/sbase-box";
		}
	}

	return null;
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
		} else if ( std.mem.eql( u8, cmd0, "fork" ) ) {
			const res = try h( system.vfork() );
			print( "fork:{} {}\n", .{ res, system.getpid() } );
		} else if ( std.mem.eql( u8, cmd0, "help" ) ) {
			const cmd1 = iter.next() orelse "";
			if ( std.mem.eql( u8, cmd1, "recvudp" ) ) {
				write( "ipaddr [netdev file]\n" );
				write( "ipaddr [netdev file] [ipv4 address] [mask]\n" );
			} else if ( std.mem.eql( u8, cmd1, "recvudp" ) ) {
				write( "recvudp [port]\n" );
			} else if ( std.mem.eql( u8, cmd1, "recvudpd" ) ) {
				write( "recvudpd [ports...]\n" );
			} else if ( std.mem.eql( u8, cmd1, "sendudp" ) ) {
				write( "sendudp [ipv4 address] [port] [data...]\n" );
			} else {
				write( "commands: ipaddr, recvudp, recvudpd, sendudp, exit, kpanic, panic\n" );
			}
		} else if ( std.mem.eql( u8, cmd0, "recvudp" ) ) {
			const sock: i32 = @bitCast( try h( linux.socket( linux.PF.INET, linux.SOCK.DGRAM, linux.IPPROTO.UDP ) ) );
			defer _ = linux.close( sock );

			var src: net.sockaddr.Ipv4 = undefined;
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

			var src: net.sockaddr.Ipv4 = undefined;
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
			const sock: i32 = @bitCast( try h( linux.socket( linux.PF.INET, linux.SOCK.DGRAM, linux.IPPROTO.UDP ) ) );
			const buf = iter.rest();

			_ = try h( linux.sendto( sock, buf.ptr, buf.len, 0, @ptrCast( &dst.sa ), @sizeOf( linux.sockaddr.in ) ) );
			_ = try h( linux.close( sock ) );
		} else if ( std.mem.eql( u8, cmd0, "ipaddr" ) ) {
			const path = try alloc.dupeZ( u8, iter.next() orelse return );
			defer alloc.free( path );

			const fd: i32 = @bitCast( try h( system.open( path, 0, 0 ) ) );
			defer _ = system.close( fd );

			var route = net.ipv4.Route {
				.srcAddress = .{ .val = 0 },
				.dstNetwork = .{ .val = 0 },
				.dstMask = .{ .val = 0 },
				.viaAddress = .{ .val = 0 }
			};

			if ( iter.next() ) |str| {
				const addr = std.net.Ip4Address.parse( str, 0 ) catch return;
				route.srcAddress = .{ .val = addr.sa.addr };
				route.dstMask = net.ipv4.Mask.init(
					std.fmt.parseInt( u6, iter.next() orelse return, 0 ) catch return
				);
				route.dstNetwork = .{ .val = addr.sa.addr & route.dstMask.val };
				route.viaAddress = .{ .val = route.dstNetwork.val | ( ( ~route.dstMask.val ) & ( @as( u32, 1 ) << 24 ) ) };
			}

			_ = try h( system.ioctl( fd, 0, @intFromPtr( &route ) ) );
			if ( route.srcAddress.val == 0 ) {
				write( "null\n" );
			} else {
				print( "{}\n", .{ route } );
			}
		} else if ( extractBin( cmd0 ) ) |bin| {
			var arena = std.heap.ArenaAllocator.init( alloc );
			const aalloc = arena.allocator();
			defer arena.deinit();

			const argv0 = try aalloc.allocSentinel( u8, 5 + cmd0.len, 0 );
			@memcpy( argv0[0..5], "/bin/" );
			@memcpy( argv0[5..], cmd0 );

			const argv = try aalloc.allocSentinel( ?[*:0]u8, std.mem.count( u8, iter.rest(), " " ) + 2, null );
			@memset( argv, null );
			argv[0] = argv0.ptr;

			var i: usize = 1;
			while ( iter.next() ) |arg| : ( i += 1 ) {
				argv[i] = ( try aalloc.dupeZ( u8, arg ) ).ptr;
			}

			if ( try h( system.vfork() ) == 0 ) {
				_ = try h( system.execve( bin, argv.ptr, undefined ) );
			}
		} else {
			print( "! Unknown command: \"{s}\"\n", .{ cmd0 } );
		}
	}
}
