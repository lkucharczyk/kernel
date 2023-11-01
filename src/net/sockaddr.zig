const std = @import( "std" );

pub const Family = enum(u16) {
	Unspecified =  0,
	Unix        =  1,
	Ipv4        =  2,
	Ipv6        = 10,
	_
};

pub const Unknown = extern struct {
	family: Family
};

pub const Unix = extern struct {
	family: Family = .Unix,
	path: [107:0]u8,

	pub inline fn len( self: Unix ) usize {
		return @sizeOf( Family ) + std.mem.indexOfSentinel( u8, 0, self.path );
	}
};

pub const Ipv4 = extern struct {
	family: Family = .Ipv4,
	port: u16,
	address: @import( "./ipv4.zig" ).Address,

	pub fn format( self: Ipv4, _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		try std.fmt.format( writer, "{s}{{ {}:{} }}", .{ @typeName( Ipv4 ), self.address, self.port } );
	}
};

pub const Ipv6 = extern struct {
	family: Family = .Ipv6,
	port: u16,
	flowInfo: u32,
	address: u128,
	scope: u32
};

pub const Sockaddr = extern union {
	unknown: Unknown,
	unix: Unix,
	ipv4: Ipv4,
	ipv6: Ipv6,

	pub fn format( self: Sockaddr, comptime fmt: []const u8, fo: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		try switch ( self.unknown.family ) {
			.Ipv4 => self.ipv4.format( fmt, fo, writer ),
			.Ipv6 => std.fmt.format( writer, "{}", .{ self.ipv6 } ),
			.Unix => std.fmt.format( writer, "{}", .{ self.unix } ),
			else => std.fmt.format( writer, "{}", .{ self.unknown } )
		};
	}
};
