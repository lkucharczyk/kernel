const std = @import( "std" );
const root = @import( "root" );
const irq = @import( "./irq.zig" );
const task = @import( "./task.zig" );
const x86 = @import( "./x86.zig" );

pub const Syscall = enum(u32) {
	Read   = 0,
	Write  = 1,
	Open   = 2,
	Close  = 3,
	Socket = 41,
	SendTo = 44,
	Exit   = 60,
	_
};

fn handlerIrq( state: *x86.State ) void {
	const id: Syscall = switch ( state.eax ) {
		1 => Syscall.Exit,
		3 => Syscall.Read,
		4 => Syscall.Write,
		5 => Syscall.Open,
		6 => Syscall.Close,
		102 => _: {
			var args: [*]u32 = @ptrFromInt( state.ecx );

			break :_ switch ( state.ebx ) {
				1 => {
					state.ebx = args[0];
					state.ecx = args[1];
					state.edx = args[2];
					break :_ Syscall.Socket;
				},
				11 => {
					state.ebx = args[0];
					state.ecx = args[1];
					state.edx = args[2];
					state.esi = args[3];
					state.edi = args[4];
					state.ebp = args[5];
					break :_ Syscall.SendTo;
				},
				else => return
			};
		},
		359 => Syscall.Socket,
		369 => Syscall.SendTo,
		else => return
	};

	state.errNum = @bitCast( handler( id, state.ebx, state.ecx, state.edx, state.esi, state.edi, state.ebp ) );
}

fn handler( id: Syscall, arg0: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize ) isize {

	if ( id != .Read and id != .Write ) {
		root.log.printUnsafe( "syscall: task:{} {}(", .{ task.currentTask.id, id } );
	}

	var out: isize = switch ( id ) {
		// read( fd, bufPtr, bufLen )
		.Read => _: {
			if ( task.currentTask.fd.items.len > arg0 ) {
				if ( task.currentTask.fd.items[arg0] ) |fd| {
					x86.enableInterrupts();
					var out: isize = @bitCast( fd.read( @as( [*]u8, @ptrFromInt( arg1 ) )[0..arg2] ) );
					x86.disableInterrupts();

					break :_ out;
				}
			}

			// TODO: set task's errno to EBADF
			break :_ -1;
		},
		// write( fd, bufPtr, bufLen )
		.Write => _: {
			if ( task.currentTask.fd.items.len > arg0 ) {
				if ( task.currentTask.fd.items[arg0] ) |fd| {
					break :_ @bitCast( fd.write( @as( [*]u8, @ptrFromInt( arg1 ) )[0..arg2] ) );
				}
			}

			// TODO: set task's errno to EBADF
			break :_ -1;
		},
		// open( pathPtr, flags, mode )
		.Open => _: {
			root.log.printUnsafe( " {}, {}, {} ", .{ arg0, arg1, arg2 } );

			const pathPtr = @as( [*:0]const u8, @ptrFromInt( arg0 ) );
			const path = pathPtr[1..std.mem.indexOfSentinel( u8, 0, pathPtr )];

			if ( @import( "./vfs.zig" ).rootNode.resolveDeep( path ) ) |node| {
				for ( task.currentTask.fd.items, 0.. ) |*fd, i| {
					if ( fd.* == null ) {
						fd.* = .{ .node = node };
						break :_ @bitCast( i );
					}
				}

				( task.currentTask.fd.addOne( root.kheap ) catch unreachable ).* = .{ .node = node };
				break :_ @bitCast( task.currentTask.fd.items.len - 1 );
			}

			break :_ -1;
		},
		// close( fd )
		.Close => _: {
			root.log.printUnsafe( " {} ", .{ arg0 } );

			if ( task.currentTask.fd.items.len > arg0 ) {
				if ( task.currentTask.fd.items[arg0] != null ) {
					task.currentTask.fd.items[arg0].?.node.close();
					task.currentTask.fd.items[arg0] = null;
					break :_ 0;
				}
			}

			break :_ -1;
		},
		// socket( family, type, protocol )
		.Socket => _: {
			root.log.printUnsafe( " {}, {}, {} ", .{ arg0, arg1, arg2 } );

			var node = @import( "./net.zig" ).createSocket();

			for ( task.currentTask.fd.items, 0.. ) |*fd, i| {
				if ( fd.* == null ) {
					fd.* = .{ .node = node };
					break :_ @bitCast( i );
				}
			}

			( task.currentTask.fd.addOne( root.kheap ) catch unreachable ).* = .{ .node = node };
			break :_ @bitCast( task.currentTask.fd.items.len - 1 );
		},
		// sendto( fd, bufPtr, bufLen, flags, sockaddrPtr, sockaddrLen )
		.SendTo => _: {
			var buf = @as( [*]u8, @ptrFromInt( arg1 ) )[0..arg2];
			var sockaddr: @import( "./net/sockaddr.zig" ).Sockaddr = undefined;

			const mlen = @min( @sizeOf( @import( "./net/sockaddr.zig" ).Sockaddr ), arg5 );
			@memcpy(
				@as( [*]u8, @ptrCast( &sockaddr ) )[0..mlen],
				@as( [*]u8, @ptrFromInt( arg4 ) )[0..mlen]
			);

			root.log.printUnsafe( " {}, \"{s}\", {}, {} ", .{ arg0, buf, arg3, sockaddr } );

			if ( task.currentTask.fd.items.len > arg0 ) {
				if ( task.currentTask.fd.items[arg0] ) |fd| {
					if ( fd.node.ntype == .Socket ) {
						var socket: *@import( "./net/socket.zig" ).Socket = @alignCast( @ptrCast( fd.node.ctx ) );

						break :_ socket.sendto( sockaddr, buf );
					}
				}
			}

			// TODO: set task's errno to EBADF
			break :_ -1;
		},
		.Exit => {
			root.log.printUnsafe( " {} ) => noreturn", .{ arg0 } );
			// root.log.printUnsafe(
			// 	"\nsyscall: task:{} {}( {} )\n",
			// 	.{ task.currentTask.id, id, arg0 }
			// );
			task.currentTask.exit( arg0 );
		},
		else => -1
	};

	if ( id != .Read and id != .Write ) {
		// root.log.printUnsafe(
		//	"syscall: task:{} {}( {}, {}, {}, {}, {}, {} ) => {}\n",
		//	.{ task.currentTask.id, id, arg0, arg1, arg2, arg3, arg4, arg5, out }
		// );

		root.log.printUnsafe( ") => {}\n", .{ out } );
	}

	return out;
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
