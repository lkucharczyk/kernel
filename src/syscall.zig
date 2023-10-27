const std = @import( "std" );
const root = @import( "root" );
const irq = @import( "./irq.zig" );
const task = @import( "./task.zig" );
const x86 = @import( "./x86.zig" );

pub const Syscall = enum(u32) {
	Write = 1,
	Exit  = 60
};

fn handler( state: *x86.State ) void {
	const id: Syscall = @enumFromInt( state.eax );

	state.errNum = switch ( id ) {
		.Write => switch ( state.edi ) {
			1, 2 => @intCast( @as( u32, @intCast(
				root.log.write( @as( [*]const u8, @ptrFromInt( state.esi ) )[0..state.edx] )
					catch unreachable
			) ) ),
			// TODO: set task's errno to EBADF
			else => -1
		},
		.Exit => {
			// root.log.printUnsafe(
			// 	"\nsyscall: task:{} {}( {} )\n",
			// 	.{ task.currentTask.id, id, state.edi }
			// );
			task.currentTask.exit( state, state.edi );
		}
	};

	// root.log.printUnsafe(
	// 	"\nsyscall: task:{} {}( {}, {}, {} ) => {}\n",
	// 	.{ task.currentTask.id, id, state.edi, state.esi, state.edx, state.errNum }
	// );
}

pub fn init() void {
	irq.set( irq.Interrupt.Syscall, handler );
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

	return asm volatile (
		\\ int $0x80
		: [out] "={eax}" ( -> i32 )
		:
			[id] "{eax}" ( @intFromEnum( id ) ),
			[arg0] "{edi}" ( syscallArgs[0] ),
			[arg1] "{esi}" ( syscallArgs[1] ),
			[arg2] "{edx}" ( syscallArgs[2] )
	);
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
