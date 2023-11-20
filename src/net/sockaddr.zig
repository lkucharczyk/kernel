const std = @import( "std" );
const net = @import( "../net.zig" );
const netUtil = @import( "./util.zig" );

pub const Family = enum(u16) {
	Unspecified = 0,
	Unix        = 1,
	Ipv4        = 2,
	Ipv6        = 10,
	Packet      = 17,
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
	port: u16 = 0,
	address: @import( "./ipv4.zig" ).Address = @import( "./ipv4.zig" ).Address.Any,

	pub fn format( self: Ipv4, _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		try std.fmt.format( writer, "{}:{}", .{ self.address, netUtil.hton( u16, self.port ) } );
	}
};

pub const Ipv6 = extern struct {
	family: Family = .Ipv6,
	port: u16,
	flowInfo: u32,
	address: u128,
	scope: u32
};

pub const Packet = extern struct {
	const Type = enum(u8) {
		LocalHost = 0,
		Broadcast = 1,
		Multicast = 2,
		OtherHost = 3,
		_
	};

	family: Family = .Packet,
	protocol: net.ethernet.EtherType,
	index: u32,
	hwType: net.arp.HwType,
	ptype: Type,
	hwAddrLen: u8,
	hwAddr: [6]u8
};

pub const Sockaddr = extern union {
	unknown: Unknown,
	unix: Unix,
	ipv4: Ipv4,
	ipv6: Ipv6,

	pub fn getPort( self: Sockaddr ) u16 {
		return net.util.hton( u16, switch ( self.unknown.family ) {
			.Ipv4 => self.ipv4.port,
			.Ipv6 => self.ipv6.port,
			else => 0
		} );
	}

	pub inline fn setPort( self: *align(4) Sockaddr, port: u16 ) void {
		self.setPortNet( net.util.hton( u16, port ) );
	}

	pub fn setPortNet( self: *align(4) Sockaddr, port: u16 ) void {
		switch ( self.unknown.family ) {
			.Ipv4 => { self.ipv4.port = port; },
			.Ipv6 => { self.ipv6.port = port; },
			else => {}
		}
	}

	pub fn getSize( self: Sockaddr ) usize {
		return switch ( self.unknown.family ) {
			.Ipv4 => @sizeOf( Ipv4 ),
			.Ipv6 => @sizeOf( Ipv6 ),
			.Unix => @sizeOf( Unix ),
			else => 0
		};
	}

	pub fn format( self: Sockaddr, comptime fmt: []const u8, fo: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		try switch ( self.unknown.family ) {
			.Ipv4 => self.ipv4.format( fmt, fo, writer ),
			.Ipv6 => std.fmt.format( writer, "{}", .{ self.ipv6 } ),
			.Unix => std.fmt.format( writer, "{}", .{ self.unix } ),
			else => std.fmt.format( writer, "{}", .{ self.unknown } )
		};
	}
};
