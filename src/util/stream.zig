const std = @import( "std" );

pub const AnySeekableStream = struct {
	context: *anyopaque,
	fnGetEndPos: *const fn( *anyopaque ) anyerror!u64,
	fnGetPos: *const fn( *anyopaque ) anyerror!u64,
	fnSeekBy: *const fn( *anyopaque, i64 ) anyerror!void,
	fnSeekTo: *const fn( *anyopaque, u64 ) anyerror!void,

	pub fn fromSeekableStream( stream: anytype ) AnySeekableStream {
		return .{
			.context = stream.context,
			.fnGetEndPos = @TypeOf( stream ).getEndPos,
			.fnGetPos = @TypeOf( stream ).getPos,
			.fnSeekBy = @TypeOf( stream ).seekBy,
			.fnSeekTo = @TypeOf( stream ).seekTo
		};
	}

	pub fn getEndPos( self: AnySeekableStream ) anyerror!u64 {
		return self.fnGetEndPos( self.context );
	}

	pub fn getPos( self: AnySeekableStream ) anyerror!u64 {
		return self.fnGetPos( self.context );
	}

	pub fn seekBy( self: AnySeekableStream, offset: i64 ) anyerror!void {
		return self.fnSeekBy( self.context, offset );
	}

	pub fn seekTo( self: AnySeekableStream, pos: u64 ) anyerror!void {
		return self.fnSeekTo( self.context, pos );
	}
};

pub const Stream = struct {
	const VTable = struct {
		read:  ?*const fn( ?*anyopaque, []u8 ) anyerror!usize = null,
		write: ?*const fn( ?*anyopaque, []const u8 ) anyerror!usize = null
	};

	context: ?*anyopaque,
	vtable: VTable,

	pub inline fn read( self: *Stream, buf: []u8 ) anyerror!usize {
		if ( self.vtable.read ) |fnRead| {
			return try fnRead( self.context, buf );
		}

		return 0;
	}

	pub fn write( self: *Stream, buf: []const u8 ) anyerror!usize {
		if ( self.vtable.write ) |fnWrite| {
			return fnWrite( self.context, buf );
		}

		return buf.len;
	}

	pub inline fn print( self: *Stream, comptime fmt: []const u8, args: anytype ) anyerror!void {
		try std.fmt.format( self.writer(), fmt, args );
	}

	pub inline fn printUnsafe( self: *Stream, comptime fmt: []const u8, args: anytype ) void {
		std.fmt.format( self.writer(), fmt, args ) catch unreachable;
	}

	pub inline fn writer( self: *Stream ) std.io.Writer( *Stream, anyerror, write ) {
		return .{ .context = self };
	}
};

pub const MultiWriter = struct {
	streams: []?Stream,

	pub fn write( self: *MultiWriter, buf: []const u8 ) anyerror!usize {
		var out: u32 = 0;

		for ( 0..self.streams.len ) |i| {
			if ( self.streams[i] ) |*stream| {
				out = @max( out, stream.write( buf ) catch unreachable );
			}
		}

		return buf.len;
	}

	pub fn writeUnsafe( self: *MultiWriter, buf: []const u8 ) void {
		_ = self.write( buf ) catch unreachable;
	}

	pub inline fn print( self: *MultiWriter, comptime fmt: []const u8, args: anytype ) anyerror!void {
		try std.fmt.format( self.writer(), fmt, args );
	}

	pub inline fn printUnsafe( self: *MultiWriter, comptime fmt: []const u8, args: anytype ) void {
		std.fmt.format( self.writer(), fmt, args ) catch unreachable;
	}

	pub inline fn writer( self: *MultiWriter ) std.io.Writer( *MultiWriter, anyerror, write ) {
		return .{ .context = self };
	}
};
