const std = @import( "std" );

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
