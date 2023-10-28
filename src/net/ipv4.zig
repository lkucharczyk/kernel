const std = @import( "std" );

pub const Address = packed struct(u32) {
	val: u32,

	pub fn init( o: [4]u8 ) Address {
		return .{
			.val =
				(   @as( u32, o[3] ) << 24 )
				| ( @as( u32, o[2] ) << 16 )
				| ( @as( u32, o[1] ) <<  8 )
				| ( @as( u32, o[0] ) <<  0 )
		};
	}

	pub fn format( self: Address, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) !void {
		try std.fmt.format( writer, "{}.{}.{}.{}", .{
			self.val           & 0xff,
			( self.val >>  8 ) & 0xff,
			( self.val >> 16 ) & 0xff,
			( self.val >> 24 ) & 0xff
		} );
	}
};
