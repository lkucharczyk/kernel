const std = @import( "std" );

pub fn OptionalVal( comptime T: type, comptime fmt: []const u8 ) type {
	return struct {
		data: ?T,
		pub fn format( self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
			if ( self.data ) |data| {
				try std.fmt.format( writer, fmt, .{ data } );
			} else {
				_ = try writer.write( "null" );
			}
		}
	};
}

pub const OptionalCStr = OptionalVal( [*:0]const u8, "\"{s}\"" );
