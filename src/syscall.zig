const std = @import( "std" );
const root = @import( "root" );
const irq = @import( "./irq.zig" );
const task = @import( "./task.zig" );
const net = @import( "./net.zig" );
const x86 = @import( "./x86.zig" );

pub const Syscall = enum(u32) {
	Read     = 0,
	Write    = 1,
	Open     = 2,
	Close    = 3,
	Poll     = 7,
	Socket   = 41,
	SendTo   = 44,
	RecvFrom = 45,
	Bind     = 49,
	Exit     = 60,
	_
};

fn handlerIrq( state: *x86.State ) void {
	var args: [6]usize = .{ state.ebx, state.ecx, state.edx, state.esi, state.edi, state.ebp };
	const id: Syscall = switch ( state.eax ) {
		1 => Syscall.Exit,
		3 => Syscall.Read,
		4 => Syscall.Write,
		5 => Syscall.Open,
		6 => Syscall.Close,
		102 => _: {
			var argPtr: [*]u32 = @ptrFromInt( state.ecx );
			var argCount: u8 = 0;
			var argId: Syscall = undefined;

			switch ( state.ebx ) {
				1 => {
					argCount = 3;
					argId = Syscall.Socket;
				},
				2 => {
					argCount = 3;
					argId = Syscall.Bind;
				},
				11 => {
					argCount = 6;
					argId = Syscall.SendTo;
				},
				12 => {
					argCount = 6;
					argId = Syscall.RecvFrom;
				},
				else => return
			}

			for ( 0..argCount ) |i| {
				args[i] = argPtr[i];
			}

			break :_ argId;
		},
		168 => Syscall.Poll,
		359 => Syscall.Socket,
		361 => Syscall.Bind,
		369 => Syscall.SendTo,
		371 => Syscall.RecvFrom,
		else => {
			root.log.printUnsafe( "syscall: Unknown:{}\n", .{ state.eax } );
			state.eax = @as( u32, @bitCast( @as( i32, -1 ) ) );
			return;
		}
	};

	state.eax = @bitCast( handlerWrapper( id, args ) );
}

fn extractSlice( comptime T: type, ptr: usize, len: usize ) error{ InvalidPointer }![]T {
	if ( ptr == 0 ) {
		return error.InvalidPointer;
	}

	return @as( [*]T, @ptrFromInt( ptr ) )[0..len];
}

fn extractCStr( ptr: usize ) error{ InvalidPointer }![]const u8 {
	if ( ptr == 0 ) {
		return error.InvalidPointer;
	}

	const str = @as( [*:0]const u8, @ptrFromInt( ptr ) );
	return str[0..std.mem.indexOfSentinel( u8, 0, str )];
}

fn handlerWrapper( id: Syscall, args: [6]usize ) isize {
	if ( id != .Read and id != .Write ) {
		root.log.printUnsafe( "syscall: task:{} {s}(", .{ task.currentTask.id, @tagName( id ) } );
	}

	if ( handler( id, args ) ) |val| {
		if ( id != .Read and id != .Write ) {
			root.log.printUnsafe( ") => {}\n", .{ val } );
		}

		return val;
	} else |err| {
		task.currentTask.errno = task.Errno.fromError( err );
		var val: isize = task.currentTask.errno.getResult();

		if ( id != .Read and id != .Write ) {
			root.log.printUnsafe( ") => {} ({})\n", .{ val, task.currentTask.errno } );
		}

		return val;
	}
}

fn handler( id: Syscall, args: [6]usize ) task.Error!isize {
	return switch ( id ) {
		// read( fd, bufPtr, bufLen )
		.Read => _: {
			const fd = try task.currentTask.getFd( args[0] );
			var buf = try extractSlice( u8, args[1], args[2] );

			const out: isize = @bitCast( fd.read( buf ) );

			break :_ out;
		},
		// write( fd, bufPtr, bufLen )
		.Write => _: {
			const fd = try task.currentTask.getFd( args[0] );
			const buf = try extractSlice( u8, args[1], args[2] );

			break :_ @bitCast( fd.write( buf ) );
		},
		// open( pathPtr, flags, mode )
		.Open => _: {
			const path = ( try extractCStr( args[0] ) )[1..];
			root.log.printUnsafe( " \"/{s}\", {}, {} ", .{ path, args[1], args[2] } );

			if ( @import( "./vfs.zig" ).rootNode.resolveDeep( path ) ) |node| {
				break :_ task.currentTask.addFd( node );
			}

			break :_ task.Error.PermissionDenied;
		},
		// close( fd )
		.Close => _: {
			root.log.printUnsafe( " {} ", .{ args[0] } );

			const fd = try task.currentTask.getFd( args[0] );
			fd.node.close( fd );
			task.currentTask.fd.items[args[0]] = null;
			break :_ 0;
		},
		// poll( pollfdsPtr, pollfdsLen, timeout )
		.Poll => _: {
			const fd = try extractSlice( task.PollFd, args[0], args[1] );
			const timeout: i32 = @bitCast( args[2] );
			root.log.printUnsafe( " [{}]{*}, {} ", .{ fd.len, fd.ptr, timeout } );

			if ( fd.len > 0 ) {
				task.currentTask.park( .{ .poll = .{ .fd = fd } } );
			}

			var out: i32 = 0;
			for ( fd ) |f| {
				if ( @as( u16, @bitCast( f.retEvents ) ) > 0 ) {
					out +|= 1;
				}
			}

			break :_ out;
		},
		// socket( family, type, protocol )
		.Socket => _: {
			const family: net.sockaddr.Family = @enumFromInt( args[0] );
			const protocol: net.ipv4.Protocol = @enumFromInt( args[2] );
			root.log.printUnsafe( " {}, {}, {} ", .{ family, args[1], protocol } );

			const node = try net.createSocket( family, args[1], protocol );
			break :_ task.currentTask.addFd( node );
		},
		// bind( fd, sockaddrPtr, sockaddrLen )
		.Bind => _: {
			var sockaddr: net.Sockaddr = undefined;

			const mlen = @min( @sizeOf( net.Sockaddr ), args[2] );
			@memcpy(
				@as( [*]u8, @ptrCast( &sockaddr ) )[0..mlen],
				@as( [*]const u8, @ptrFromInt( args[1] ) )[0..mlen]
			);

			root.log.printUnsafe( " {}, {} ", .{ args[0], sockaddr } );

			const fd = try task.currentTask.getFd( args[0] );
			const socket = fd.getSocket() orelse break :_ task.Error.NotSocket;

			try socket.bind( sockaddr );
			break :_ 0;
		},
		// sendto( fd, bufPtr, bufLen, flags, sockaddrPtr, sockaddrLen )
		.SendTo => _: {
			var buf: []const u8 = try extractSlice( u8, args[1], args[2] );
			var sockaddr: net.Sockaddr = undefined;

			const mlen = @min( @sizeOf( net.Sockaddr ), args[5] );
			@memcpy(
				@as( [*]u8, @ptrCast( &sockaddr ) )[0..mlen],
				try extractSlice( u8, args[4], mlen )
			);

			root.log.printUnsafe( " {}, \"{s}\", {}, {} ", .{ args[0], buf, args[3], sockaddr } );

			const fd = try task.currentTask.getFd( args[0] );
			const socket = fd.getSocket() orelse break :_ task.Error.NotSocket;

			break :_ socket.sendto( sockaddr, buf );
		},
		// recvfrom( fd, bufPtr, bufLen, flags, sockaddrPtr, sockaddrLenPtr )
		.RecvFrom => _: {
			var buf = try extractSlice( u8, args[1], args[2] );
			var addr: ?*align(1) net.Sockaddr = @ptrFromInt( args[4] );
			var addrlen: ?*align(1) u32 = @ptrFromInt( args[5] );
			root.log.printUnsafe( " {}, [{}]{*}, {}, {*}, {*} ", .{ args[0], buf.len, buf, args[3], addr, addrlen } );

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
		.Exit => {
			root.log.printUnsafe( " {} ) => noreturn", .{ args[0] } );
			task.currentTask.exit( args[0] );
		},
		else => -1
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

	var syscallArgs = argparse( args );

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
