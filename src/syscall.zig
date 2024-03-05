const std = @import( "std" );
const root = @import( "root" );
const fmtUtil = @import( "./util/fmt.zig" );
const gdt = @import( "./gdt.zig" );
const irq = @import( "./irq.zig" );
const task = @import( "./task.zig" );
const mem = @import( "./mem.zig" );
const net = @import( "./net.zig" );
const vfs = @import( "./vfs.zig" );
const x86 = @import( "./x86.zig" );
const util = @import( "./syscall/util.zig" );

const archId = switch ( @import( "builtin" ).cpu.arch ) {
	.x86_64 => 0,
	.x86    => 1,
	else    => unreachable
};
pub const Syscall = enum(u32) {
	//              .{ x64, x86 }
	Read          = .{   0,   3 }[archId],
	Write         = .{   1,   4 }[archId],
	Open          = .{   2,   5 }[archId],
	Close         = .{   3,   6 }[archId],
	Poll          = .{   7, 168 }[archId],
	LSeek         = .{   8,  19 }[archId],
	MMap          = .{   9,  90 }[archId],
	Brk           = .{  12,  45 }[archId],
	IoCtl         = .{  16,  54 }[archId],
	WriteV        = .{  20, 146 }[archId],
	Dup           = .{  32,  41 }[archId],
	Dup2          = .{  33,  63 }[archId],
	GetPid        = .{  39,  20 }[archId],
	Socket        = .{  41, 359 }[archId],
	Connect       = .{  42, 362 }[archId],
	SendTo        = .{  44, 369 }[archId],
	RecvFrom      = .{  45, 371 }[archId],
	Bind          = .{  49, 361 }[archId],
	Fork          = .{  57,   2 }[archId],
	VFork         = .{  58, 190 }[archId],
	ExecVE        = .{  59,  11 }[archId],
	Exit          = .{  60,   1 }[archId],
	Rename        = .{  82,  38 }[archId],
	Link          = .{  86,   9 }[archId],
	Unlink        = .{  87,  10 }[archId],
	GetTimeOfDay  = .{  96,  78 }[archId],
	SetThreadArea = .{ 205, 243 }[archId],
	StatX         = .{ 332, 383 }[archId],

	// TODO: NotImplemented
	Stat          = .{   4, 195 }[archId],
	FStat         = .{   5, 197 }[archId],
	LStat         = .{   6, 196 }[archId],
	MProtect      = .{  10, 125 }[archId],
	MUnmap        = .{  11,  91 }[archId],
	FCntl         = .{  72, 221 }[archId],
	GetCwd        = .{  79, 183 }[archId],
	Futex         = .{ 202, 240 }[archId],
	SetTidAddress = .{ 218, 258 }[archId],
	ExitGroup     = .{ 231, 252 }[archId],

	// _
};

fn handlerIrq( state: *x86.State ) void {
	var args: [6]usize = .{ state.ebx, state.ecx, state.edx, state.esi, state.edi, state.ebp };
	const id: Syscall = switch ( state.eax ) {
		// x86.SocketCall
		102 => _: {
			const argPtr: [*]u32 = @ptrFromInt( state.ecx );
			var argCount: u8 = 0;
			var argId: Syscall = undefined;

			switch ( state.ebx ) {
				std.os.linux.SC.socket => {
					argCount = 3;
					argId = Syscall.Socket;
				},
				std.os.linux.SC.bind => {
					argCount = 3;
					argId = Syscall.Bind;
				},
				std.os.linux.SC.connect => {
					argCount = 3;
					argId = Syscall.Connect;
				},
				std.os.linux.SC.send => {
					args[4] = 0;
					args[5] = 0;
					argCount = 4;
					argId = Syscall.SendTo;
				},
				std.os.linux.SC.recv => {
					args[4] = 0;
					args[5] = 0;
					argCount = 4;
					argId = Syscall.RecvFrom;
				},
				std.os.linux.SC.sendto => {
					argCount = 6;
					argId = Syscall.SendTo;
				},
				std.os.linux.SC.recvfrom => {
					argCount = 6;
					argId = Syscall.RecvFrom;
				},
				else => {
					root.log.printUnsafe(
						"syscall: task:{} SocketCall:{}() => {}\n",
						.{ task.currentTask.id, state.ebx, task.Errno.NotImplemented }
					);
					state.eax = @bitCast( task.Errno.NotImplemented.getResult() );
					return;
				}
			}

			for ( 0..argCount ) |i| {
				args[i] = argPtr[i];
			}

			break :_ argId;
		},

		// TODO: x86.Mmap2 (arg[5] *= 4096 -> .MMap)
		192 => Syscall.MMap,

		else => _: {
			if ( std.meta.intToEnum( Syscall, state.eax ) ) |id| {
				break :_ id;
			} else |_| {
				root.log.printUnsafe(
					"syscall: task:{} Unknown:{}() => {}\n",
					.{ task.currentTask.id, state.eax, task.Errno.NotImplemented }
				);
				state.eax = @bitCast( task.Errno.NotImplemented.getResult() );
				return;
			}
		}
	};

	state.eax = @bitCast( handlerWrapper( id, args, state ) );
}

pub var enableStrace: bool = true;
pub fn handlerWrapper( id: Syscall, args: [6]usize, state: ?*x86.State ) isize {
	const strace = ( ( id != .Read and id != .Write and id != .WriteV ) or args[0] > 2 ) and enableStrace;
	if ( strace ) {
		root.log.printUnsafe( "syscall: task:{} {s}(", .{ task.currentTask.id, @tagName( id ) } );
	}

	if ( handler( id, args, state, strace ) ) |val| {
		if ( strace ) {
			if ( val < 0x100 and val >= -1024 ) {
				root.log.printUnsafe( ") => {}\n", .{ val } );
			} else {
				root.log.printUnsafe( ") => 0x{x}\n", .{ @as( usize, @bitCast( val ) ) } );
			}
		}

		return val;
	} else |err| {
		const errno = task.Errno.fromError( err );

		if ( strace ) {
			root.log.printUnsafe( ") => {}\n", .{ errno } );
		}

		return errno.getResult();
	}
}

fn handler( id: Syscall, args: [6]usize, state: ?*x86.State, strace: bool ) task.Error!isize {
	return switch ( id ) {
		// read( fd, bufPtr, bufLen )
		.Read => _: {
			if ( strace ) {
				root.log.printUnsafe( " {}, [0x{x}]u8@0x{x} ", .{ args[0], args[2], args[1] } );
			}

			const fd = try task.currentTask.getFd( args[0] );
			const buf = try util.extractSlice( u8, args[1], args[2] );

			break :_ @bitCast( try fd.read( buf ) );
		},
		// write( fd, bufPtr, bufLen )
		.Write => _: {
			if ( strace ) {
				root.log.printUnsafe( " {}, [0x{x}]u8@0x{x} ", .{ args[0], args[2], args[1] } );
			}

			const fd = try task.currentTask.getFd( args[0] );
			const buf = try util.extractSlice( u8, args[1], args[2] );

			break :_ @bitCast( try fd.write( buf ) );
		},
		// open( pathPtr, flags, mode )
		.Open => _: {
			const path = try util.extractPath( args[0] );
			const flags: std.os.linux.O = @bitCast( args[1] );

			if ( strace ) {
				root.log.printUnsafe( " \"/{s}\", {}, 0o{o} ", .{
					path,
					fmtUtil.BitFlagsStruct( std.os.linux.O ) { .data = flags },
					args[2]
				} );
			}

			if ( vfs.rootNode.resolveDeep( path ) ) |node| {
				const fd = try node.open();
				errdefer fd.close();

				break :_ @bitCast( try task.currentTask.addFd( fd ) );
			}

			break :_ task.Error.MissingFile;
		},
		// close( fd )
		.Close => _: {
			if ( strace ) {
				root.log.printUnsafe( " {} ", .{ args[0] } );
			}

			( try task.currentTask.getFd( args[0] ) ).close();
			task.currentTask.fd.items[args[0]] = null;
			break :_ 0;
		},
		// dup( fd )
		.Dup => _: {
			if ( strace ) {
				root.log.printUnsafe( " {} ", .{ args[0] } );
			}

			break :_ @bitCast( try task.currentTask.addFd( try task.currentTask.getFd( args[0] ) ) );
		},
		// dup2( oldfd, newfd )
		.Dup2 => _: {
			if ( strace ) {
				root.log.printUnsafe( " {}, {} ", .{ args[0], args[1] } );
			}

			if ( task.currentTask.getFd( args[0] ) ) |fd| {
				fd.close();
			} else |_| {
				if ( task.currentTask.fd.items.len <= args[0] ) {
					try task.currentTask.fd.appendNTimes( root.kheap, null, args[0] - task.currentTask.fd.items.len + 1 );
				}
			}

			task.currentTask.fd.items[args[0]] = try task.currentTask.getFd( args[1] );
			break :_ @bitCast( args[0] );
		},
		// poll( pollfdsPtr, pollfdsLen, timeout )
		.Poll => _: {
			const fd = try util.extractSlice( task.PollFd, args[0], args[1] );
			const timeout: i32 = @bitCast( args[2] );
			if ( strace ) {
				root.log.printUnsafe( " [{}]{*}, {} ", .{ fd.len, fd.ptr, timeout } );
			}

			const kfd = try root.kheap.dupe( task.PollFd, fd );
			defer root.kheap.free( kfd );

			var out: i32 = 0;
			if ( kfd.len > 0 ) {
				var wait = task.PollWait { .fd = kfd };
				if ( !wait.ready( task.currentTask ) and timeout != 0 ) {
					task.currentTask.park( .{ .poll = wait } );
				}
			}

			@memcpy( fd, kfd );
			for ( fd ) |f| {
				if ( @as( u16, @bitCast( f.retEvents ) ) > 0 ) {
					out +|= 1;
				}
			}

			break :_ out;
		},
		// lseek( fd, offset, whence )
		.LSeek => _: {
			if ( strace ) {
				root.log.printUnsafe( " {}, 0x{x}, {} ", .{ args[0], args[1], args[2] } );
			}

			const fd = try task.currentTask.getFd( args[0] );
			if ( args[2] == std.os.linux.SEEK.SET ) {
				try fd.seekTo( args[1] );
			} else if ( args[2] == std.os.linux.SEEK.CUR ) {
				try fd.seekBy( args[1] );
			} else {
				break :_ task.Error.NotImplemented;
			}

			break :_ @bitCast( fd.offset );
		},
		// mmap( ?addr, len, prot, flags, ?fd, ?offset )
		.MMap => _: {
			const flags: std.os.linux.MAP = @bitCast( args[3] );
			var offset: u64 = args[5];

			// x86.MMap2
			if ( @import( "builtin" ).cpu.arch == .x86 and state != null and state.?.eax == 192 ) {
				offset *= 4096;
			}

			if ( strace ) {
				root.log.printUnsafe( " 0x{x}, 0x{x}, PROT{{ {} }}, {}, {}, 0x{x} ", .{
					args[0],
					args[1],
					fmtUtil.BitFlags( std.os.linux.PROT ) { .data = args[2] },
					fmtUtil.BitFlagsStruct( std.os.linux.MAP ) { .data = flags },
					@as( isize, @bitCast( args[4] ) ),
					offset
				} );
			}

			if ( args[1] == 0 ) {
				break :_ task.Error.InvalidArgument;
			}

			if ( ( args[2] & ~@as( usize, std.os.linux.PROT.READ | std.os.linux.PROT.WRITE | std.os.linux.PROT.EXEC ) ) != 0 ) {
				break :_ task.Error.NotImplemented;
			}

			var addr: usize = args[0];
			if ( addr == 0 ) {
				addr = std.mem.alignForward( usize, task.currentTask.programBreak, 4096 );
				_ = try handler( .Brk, .{ task.currentTask.programBreak + args[1], 0, 0, 0, 0, 0 }, state, false );
			} else {
				task.currentTask.programBreak = @max( task.currentTask.programBreak, addr + args[1] );
				if ( try task.currentTask.mmap.alloc( addr, args[1] ) ) {
					task.currentTask.mmap.map();
				}
			}

			const ptr = @as( [*]u8, @ptrFromInt( @as( usize, @bitCast( addr ) ) ) )[0..args[1]];
			if ( @as( isize, @bitCast( args[4] ) ) != -1 ) {
				var allowed: usize = std.os.linux.PROT.READ | std.os.linux.PROT.EXEC;
				if ( flags.TYPE == .PRIVATE ) {
					allowed |= std.os.linux.PROT.WRITE;
				}

				if ( ( args[2] & ~allowed ) != 0 ) {
					break :_ task.Error.NotImplemented;
				}

				const fd = try task.currentTask.getFd( args[4] );
				const o = fd.offset;
				try fd.seekTo( offset );
				defer fd.seekTo( o ) catch {};

				const s = try fd.read( ptr );
				if ( s < ptr.len ) {
					@memset( ptr[s..], 0 );
				}
			} else if ( args[0] != 0 ) {
				@memset( ptr, 0 );
			}

			break :_ @bitCast( addr );
		},
		// getpid()
		.GetPid => @as( i32, @intCast( task.currentTask.id ) ),
		// brk( addr )
		.Brk => _: {
			if ( strace ) {
				root.log.printUnsafe( " 0x{x} ", .{ args[0] } );
			}
			const prevBrk = task.currentTask.programBreak;

			if ( args[0] > prevBrk ) {
				if ( try task.currentTask.mmap.alloc( prevBrk, args[0] - prevBrk ) ) {
					task.currentTask.map();
				}

				@memset( @as( [*]u8, @ptrFromInt( prevBrk ) )[0..( args[0] - prevBrk )], 0 );
				task.currentTask.programBreak = args[0];
			} else if ( args[0] > 0 and args[0] < prevBrk ) {
				if ( task.currentTask.mmap.free( args[0], prevBrk - args[0] ) ) {
					task.currentTask.map();
				}

				task.currentTask.programBreak = args[0];
			}

			break :_ @bitCast( task.currentTask.programBreak );
		},
		// ioctl( fd, cmd, arg )
		.IoCtl => _: {
			if ( strace ) {
				root.log.printUnsafe( " {}, ", .{ args[0] } );

				switch ( args[1] ) {
					std.os.linux.T.IOCGWINSZ => root.log.writeUnsafe( "TIOCGWINSZ" ),
					else => root.log.printUnsafe( "0x{x}", .{ args[1] } )
				}

				root.log.printUnsafe( ", 0x{x} ", .{ args[2] } );
			}

			const fd = try task.currentTask.getFd( args[0] );
			break :_ ( fd.node.vtable.ioctl orelse break :_ error.BadFileDescriptor )( fd.node, fd, args[1], args[2] );
		},
		// writev( fd, iovecPtr, iovecLen )
		.WriteV => _: {
			const iovec = try util.extractSlice( std.os.iovec_const, args[1], args[2] );
			if ( strace ) {
				root.log.printUnsafe( " {}, [{}]{any} ", .{ args[0], args[2], iovec } );
			}

			const fd = try task.currentTask.getFd( args[0] );
			var out: usize = 0;
			for ( iovec ) |iov| {
				if ( iov.iov_len > 0 ) {
					const buf = try util.extractSlice( u8, @intFromPtr( iov.iov_base ), iov.iov_len );
					out += try fd.write( buf );
				}
			}

			break :_ @bitCast( out );
		},
		// socket( family, type, protocol )
		.Socket => _: {
			const family: net.sockaddr.Family = @enumFromInt( args[0] );
			const protocol: net.ipv4.Protocol = @enumFromInt( args[2] );

			if ( strace ) {
				root.log.printUnsafe( " {}, {}, {} ", .{ family, args[1], protocol } );
			}

			const sock = try net.createSocket( family, args[1], protocol );
			errdefer sock.deinit();

			const fd = try sock.node.open();
			errdefer fd.close();

			break :_ @bitCast( try task.currentTask.addFd( fd ) );
		},
		// connect( fd, sockaddrPtr, sockaddrLen )
		.Connect => _: {
			var sockaddr: net.Sockaddr = undefined;

			const mlen = @min( @sizeOf( net.Sockaddr ), args[2] );
			@memcpy(
				@as( [*]u8, @ptrCast( &sockaddr ) )[0..mlen],
				@as( [*]const u8, @ptrFromInt( args[1] ) )[0..mlen]
			);

			if ( strace ) {
				root.log.printUnsafe( " {}, {} ", .{ args[0], sockaddr } );
			}

			const fd = try task.currentTask.getFd( args[0] );
			const socket = fd.getSocket() orelse break :_ task.Error.NotSocket;

			try socket.connect( sockaddr );
			break :_ 0;
		},
		// bind( fd, sockaddrPtr, sockaddrLen )
		.Bind => _: {
			var sockaddr: net.Sockaddr = undefined;

			const mlen = @min( @sizeOf( net.Sockaddr ), args[2] );
			@memcpy(
				@as( [*]u8, @ptrCast( &sockaddr ) )[0..mlen],
				@as( [*]const u8, @ptrFromInt( args[1] ) )[0..mlen]
			);

			if ( strace ) {
				root.log.printUnsafe( " {}, {} ", .{ args[0], sockaddr } );
			}

			const fd = try task.currentTask.getFd( args[0] );
			const socket = fd.getSocket() orelse break :_ task.Error.NotSocket;

			try socket.bind( sockaddr );
			break :_ 0;
		},
		// sendto( fd, bufPtr, bufLen, flags, sockaddrPtr, sockaddrLen )
		.SendTo => _: {
			const buf: []const u8 = try util.extractSlice( u8, args[1], args[2] );
			var sockaddr: net.Sockaddr = undefined;

			const mlen = @min( @sizeOf( net.Sockaddr ), args[5] );
			@memcpy(
				@as( [*]u8, @ptrCast( &sockaddr ) )[0..mlen],
				try util.extractSlice( u8, args[4], mlen )
			);

			if ( strace ) {
				root.log.printUnsafe( " {}, [0x{x}]u8@0x{x}, {}, {} ", .{ args[0], buf.len, args[1], args[3], sockaddr } );
			}

			const fd = try task.currentTask.getFd( args[0] );
			const socket = fd.getSocket() orelse break :_ task.Error.NotSocket;

			break :_ @bitCast( try socket.sendto( sockaddr, buf ) );
		},
		// recvfrom( fd, bufPtr, bufLen, flags, sockaddrPtr, sockaddrLenPtr )
		.RecvFrom => _: {
			var buf = try util.extractSlice( u8, args[1], args[2] );
			const addr: ?*align(1) net.Sockaddr = @ptrFromInt( args[4] );
			const addrlen: ?*align(1) u32 = @ptrFromInt( args[5] );

			if ( strace ) {
				root.log.printUnsafe( " {}, [{}]{*}, {}, {*}, {*} ", .{ args[0], buf.len, buf, args[3], addr, addrlen } );
			}

			const fd = try task.currentTask.getFd( args[0] );
			const socket = fd.getSocket() orelse break :_ task.Error.NotSocket;

			const out = socket.recvfrom( fd );

			const blen = @min( out.data.len, buf.len );
			@memcpy( buf[0..blen], out.data[0..blen] );

			if ( addrlen ) |al| {
				const mlen = @min( out.srcAddr.getSize(), al.* );
				if ( addr ) |a| {
					@memcpy(
						@as( [*]u8, @ptrCast( a ) )[0..mlen],
						@as( [*]const u8, @ptrCast( &out.srcAddr ) )[0..mlen]
					);
				}
			}

			socket.alloc.free( out.data );

			break :_ @bitCast( out.data.len );
		},
		.Fork => _: {
			if ( state == null ) {
				break :_ task.Error.PermissionDenied;
			}

			break :_ ( try task.currentTask.fork( state.? ) ).id;
		},
		.VFork => _: {
			if ( state == null ) {
				break :_ task.Error.PermissionDenied;
			}

			if ( strace ) {
				root.log.printUnsafe( "\n", .{} );
			}

			const fork = try task.currentTask.fork( state.? );
			const pid = fork.id;

			task.currentTask.park( .{ .task = fork } );

			break :_ pid;
		},
		.ExecVE => _: {
			if ( state == null ) {
				break :_ task.Error.PermissionDenied;
			}

			const path = try util.extractCStr( args[0] );

			var arena = std.heap.ArenaAllocator.init( root.kheap );
			const alloc = arena.allocator();
			defer arena.deinit();

			var execArgs = [2][][*:0]const u8 { &.{}, &.{} };
			inline for ( 0..2 ) |i| {
				if ( args[i + 1] != 0 ) {
					const slice: []?[*:0]const u8 = try util.extractSliceZ( ?[*:0]const u8, null, args[i + 1] );
					execArgs[i] = try alloc.alloc( [*:0]const u8, slice.len );
					for ( 0..slice.len ) |j| {
						execArgs[i][j] = try alloc.dupeZ( u8, try util.extractCStr( @intFromPtr( slice[j].? ) ) );
					}
				}
			}

			if ( strace ) {
				root.log.printUnsafe( " \"{s}\", [{}]{s}, [{}]{s} ", .{ path, execArgs[0].len, execArgs[0], execArgs[1].len, execArgs[1] } );
			}

			if ( vfs.rootNode.resolveDeep( path[1..] ) ) |node| {
				const fd = try node.open();
				defer fd.close();

				for ( task.currentTask.mmap.entries.items ) |e| {
					mem.freePhysical( e.phys );
				}

				if ( task.currentTask.bin ) |prev| {
					root.kheap.free( prev );
				}

				task.currentTask.bin = try root.kheap.dupeZ( u8, path );
				task.currentTask.loadElf( fd.reader(), fd.seekableStream(), execArgs ) catch |err| {
					root.log.printUnsafe( ") => noreturn ({})", .{ err } );
					task.currentTask.exit( 1 );
				};

				state.?.eip = @intFromPtr( task.currentTask.entrypoint );
				state.?.uesp = task.currentTask.stackBreak;
				state.?.ebp = task.currentTask.stackBreak;

				task.currentTask.map();

				break :_ 0;
			}

			break :_ error.MissingFile;
		},
		.Exit => {
			if ( strace ) {
				root.log.printUnsafe( " 0x{x} ) => noreturn\n", .{ args[0] } );
			}

			for ( 0..task.currentTask.fd.items.len ) |fd| {
				if ( task.currentTask.fd.items[fd] != null ) {
					_ = handler( .Close, .{ fd } ++ .{ undefined } ** 5, state, false ) catch {};
				}
			}

			task.currentTask.exit( args[0] );
		},
		.GetCwd => _: {
			if ( strace ) {
				root.log.printUnsafe( " [0x{x}]u8@0x{x} ", .{ args[1], args[0] } );
			}

			const buf = try util.extractSlice( u8, args[0], args[1] );
			if ( buf.len < 2 ) {
				break :_ task.Error.OutOfRange;
			}

			@memcpy( buf[0..1:0], "/" );
			break :_ @bitCast( args[0] );
		},
		.Rename => @import( "./syscall/vfs.zig" ).rename( args, state, strace ),
		.Link => @import( "./syscall/vfs.zig" ).link( args, state, strace ),
		.Unlink => @import( "./syscall/vfs.zig" ).unlink( args, state, strace ),
		.GetTimeOfDay => _: {
			const tv = try util.extractPtr( std.os.timeval, args[0] );
			const tz = try util.extractOptionalPtr( std.os.linux.timezone, args[1] );

			if ( strace ) {
				root.log.printUnsafe( " {*}, {?*} ", .{ tv, tz } );
			}

			if ( tz != null ) {
				break :_ task.Error.NotImplemented;
			}

			tv.tv_sec = @import( "./rtc.zig" ).getEpoch();
			tv.tv_usec = 0;

			break :_ 0;
		},
		.SetThreadArea => _: {
			const ud = try util.extractPtr( std.os.linux.user_desc, args[0] );
			if ( strace ) {
				root.log.printUnsafe( " {} \n", .{ ud } );
			}

			if ( state == null ) {
				break :_ task.Error.InvalidArgument;
			}

			if (
				ud.flags.seg_32bit == 0
				or (
					@as( isize, @bitCast( ud.entry_number ) ) != -1
					and @as( isize, @bitCast( ud.entry_number ) ) != ( gdt.Segment.TLS >> 3 )
				)
			) {
				break :_ task.Error.NotImplemented;
			}

			ud.entry_number = gdt.Segment.TLS >> 3;
			gdt.table[ud.entry_number].set(
				ud.base_addr,
				@truncate( ud.limit ),
				.{
					.present = ud.flags.seg_not_present == 0,
					.executable = true,
					.rw = true,
					.ring = if ( task.currentTask.kernelMode ) 0 else 3
				},
				.{}
			);

			task.currentTask.tls = gdt.table[ud.entry_number];
			state.?.gs = gdt.Segment.TLS;
			break :_ 0;
		},
		.StatX => @import( "./syscall/vfs.zig" ).statx( args, state, strace ),
		else => task.Error.NotImplemented
	};
}

pub fn init() void {
	irq.set( irq.Interrupt.Syscall, handlerIrq );
}

fn argparse( args: anytype ) [3]u32 {
	var out = [3]u32 { 0, 0, 0 };

	comptime var j = 0;
	inline for ( args, 0.. ) |arg, i| {
		const ati = @typeInfo( @TypeOf( arg ) );
		out[i + j] = switch ( ati ) {
			.Pointer => |p| _: {
				if ( @typeInfo( p.child ) == .Array ) {
					j += 1;
					out[i + j] = arg.len;
				} else if ( p.size == .Slice ) {
					j += 1;
					out[i + j] = @truncate( arg.len );
					break :_ @truncate( @intFromPtr( arg.ptr ) );
				}

				break :_ @truncate( @intFromPtr( arg ) );
			},
			.ComptimeInt => arg,
			.Int => @intCast( arg ),
			else => @compileError( std.fmt.comptimePrint( "invalid syscall arg: {}", .{ ati } ) )
		};
	}

	return out;
}

pub fn call( id: Syscall, args: anytype ) i32 {
	const ti = @typeInfo( @TypeOf( args ) );
	if ( ti != .Struct or ti.Struct.fields.len > 3 ) {
		@compileError( "expected tuple" );
	}

	const syscallArgs = argparse( args );

	return switch ( @import( "builtin" ).cpu.arch ) {
		.x86 => asm volatile (
			\\ int $0x80
			: [out] "={eax}" ( -> i32 )
			:
				[id] "{eax}" ( @intFromEnum( id ) ),
				[arg0] "{ebx}" ( syscallArgs[0] ),
				[arg1] "{ecx}" ( syscallArgs[1] ),
				[arg2] "{edx}" ( syscallArgs[2] )
		),
		// .x86_64 => asm volatile (
		// 	\\ syscall
		// 	: [out] "={eax}" ( -> i32 )
		// 	:
		// 		[id] "{eax}" ( @intFromEnum( id ) ),
		// 		[arg0] "{edi}" ( syscallArgs[0] ),
		// 		[arg1] "{esi}" ( syscallArgs[1] ),
		// 		[arg2] "{edx}" ( syscallArgs[2] )
		// )
		else => -1
	};
}

test "syscall.argparse" {
	try std.testing.expectEqualDeep( [3]u32 { 0, 0, 0 }, argparse( .{} ) );
	try std.testing.expectEqualDeep( [3]u32 { 1, 0, 0 }, argparse( .{ 1 } ) );
	try std.testing.expectEqualDeep( [3]u32 { 1, 2, 0 }, argparse( .{ 1, 2 } ) );
	try std.testing.expectEqualDeep( [3]u32 { 1, 2, 3 }, argparse( .{ 1, 2, 3 } ) );

	var testVal: u32 = 15;
	try std.testing.expectEqualDeep(
		[3]u32 { 9, @truncate( @intFromPtr( &testVal ) ), 9 },
		argparse( .{ 9, &testVal, 9 } )
	);

	var testArr = [_]u32 { 10, 11, 12, 13, 14, 15 };
	try std.testing.expectEqualDeep(
		[3]u32 { 9, @truncate( @intFromPtr( &testArr ) ), testArr.len },
		argparse( .{ 9, &testArr } )
	);
	try std.testing.expectEqualDeep(
		[3]u32 { 9, @truncate( @intFromPtr( &testArr[1] ) ), 2 },
		argparse( .{ 9, testArr[1..3] } )
	);
	try std.testing.expectEqualDeep(
		[3]u32 { 9, @truncate( @intFromPtr( &testArr ) ), testArr.len },
		argparse( .{ 9, @as( []u32, &testArr ) } )
	);
}
