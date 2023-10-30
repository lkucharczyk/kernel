const std = @import( "std" );
const root = @import( "root" );
const irq = @import( "./irq.zig" );
const task = @import( "./task.zig" );
const x86 = @import( "./x86.zig" );

pub const Syscall = enum(u32) {
	Read  = 0,
	Write = 1,
	Open  = 2,
	Close = 3,
	Exit  = 60,
	_
};

fn handlerIrq( state: *x86.State ) void {
	const id: Syscall = switch ( state.eax ) {
		1 => Syscall.Exit,
		3 => Syscall.Read,
		4 => Syscall.Write,
		5 => Syscall.Open,
		6 => Syscall.Close,
		else => return
	};

	state.errNum = @bitCast( handler( id, state.ebx, state.ecx, state.edx, state.esi, state.edi ) );
}

fn handler( id: Syscall, arg0: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize ) isize {
	_ = arg4;
	_ = arg3;

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
			if ( task.currentTask.fd.items.len > arg0 ) {
				if ( task.currentTask.fd.items[arg0] != null ) {
					task.currentTask.fd.items[arg0] = null;
					break :_ 0;
				}
			}

			break :_ -1;
		},
		.Exit => {
			// root.log.printUnsafe(
			// 	"\nsyscall: task:{} {}( {} )\n",
			// 	.{ task.currentTask.id, id, arg0 }
			// );
			task.currentTask.exit( arg0 );
		},
		else => -1
	};

	// root.log.printUnsafe(
	// 	"\nsyscall: task:{} {}( {}, {}, {} ) => {}\n",
	// 	.{ task.currentTask.id, id, arg0, arg1, arg2, out }
	// );

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
