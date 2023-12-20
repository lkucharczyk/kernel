const std = @import( "std" );
const task = @import( "../task.zig" );

pub fn validateAddr( ptr: usize ) bool {
	return ptr != 0 and ( task.currentTask.kernelMode or task.currentTask.mmap.containsAddr( ptr ) );
}

pub fn validateSlice( ptr: usize, len: usize ) bool {
	return ptr != 0 and ( task.currentTask.kernelMode or task.currentTask.mmap.containsSlice( ptr, len ) );
}

pub inline fn extractPtr( comptime T: type, ptr: usize ) error{ InvalidPointer }!*T {
	if ( !validateAddr( ptr ) ) {
		return task.Error.InvalidPointer;
	}

	return @ptrFromInt( ptr );
}

pub inline fn extractOptionalPtr( comptime T: type, ptr: usize ) error{ InvalidPointer }!?*T {
	if ( ptr == 0 ) {
		return null;
	}

	return extractPtr( T, ptr );
}

pub fn extractSlice( comptime T: type, ptr: usize, len: usize ) error{ InvalidPointer }![]T {
	if ( !validateSlice( ptr, len ) ) {
		return task.Error.InvalidPointer;
	}

	return @as( [*]T, @ptrFromInt( ptr ) )[0..len];
}

pub fn extractSliceZ( comptime T: type, comptime S: T, ptr: usize ) error{ InvalidPointer }![:S]T {
	if ( ptr == 0 ) {
		return error.InvalidPointer;
	}

	const data = @as( [*:S]T, @ptrFromInt( ptr ) );
	const len = std.mem.len( data );

	if ( !validateSlice( ptr, len ) ) {
		return task.Error.InvalidPointer;
	}

	return data[0..len:S];
}

pub inline fn extractCStr( ptr: usize ) error{ InvalidPointer }![:0]const u8 {
	return extractSliceZ( u8, 0, ptr );
}
