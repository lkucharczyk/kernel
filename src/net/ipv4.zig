const std = @import( "std" );
const net = @import( "../net.zig" );

pub const Address = packed struct(u32) {
	pub const Any = Address { .val = 0 };
	pub const Localhost = Address.init( .{ 127, 0, 0, 1 } );

	val: u32,

	pub inline fn init( o: [4]u8 ) Address {
		return .{
			.val =
				(   @as( u32, @intCast( o[3] ) ) << 24 )
				| ( @as( u32, @intCast( o[2] ) ) << 16 )
				| ( @as( u32, @intCast( o[1] ) ) <<  8 )
				| ( @as( u32, @intCast( o[0] ) )       )
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

pub const Mask = packed struct(u32) {
	val: u32,

	pub fn init( val: u6 ) Mask {
		if ( val == 32 ) {
			return .{ .val = std.math.maxInt( u32 ) };
		} else {
			return .{ .val = @byteSwap(
				@as( u32, std.math.maxInt( u32 ) ) << @as( u5, @truncate( 32 - val ) )
			) };
		}
	}

	pub fn format( self: Mask, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) !void {
		var i: u32 = 0;
		for ( 0..32 ) |j| {
			i += ( self.val >> @as( u5, @truncate( j ) ) ) & 1;
		}

		try std.fmt.format( writer, "/{}", .{ i } );
	}
};

pub const Route = struct {
	dstNetwork: Address,
	dstMask: Mask,
	srcAddress: Address,
	viaAddress: Address,

	pub fn match( self: Route, dstAddress: Address ) bool {
		return ( self.dstNetwork.val & self.dstMask.val ) == ( dstAddress.val & self.dstMask.val );
	}

	pub fn format( self: Route, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) !void {
		try std.fmt.format( writer, "{s}{{ {}{} (src: {}; via: {}) }}", .{
			@typeName( Route ),
			self.dstNetwork,
			self.dstMask,
			self.srcAddress,
			self.viaAddress
		} );
	}
};

pub const Protocol = enum(u8) {
	Icmp = 1,
	Tcp  = 6,
	Udp  = 17,
	Raw  = 255,
	_
};

pub const Header = extern struct {
	const Head = packed struct(u8) {
		len: u4 = 0b0101,
		version: u4 = 0b0100
	};

	const Dsf = packed struct(u8) {
		codePoint: u6 = 0,
		ecn: u2 = 0
	};

	const Flags = packed struct(u16) {
		fragmentOffset: u13 = 0,
		moreFragments: bool = false,
		dontFragment: bool = true,
		reserved: bool = false,
	};

	head: Head = .{},
	dsf: Dsf = .{},
	len: u16 = 20,
	id: u16 = 0,
	flags: Flags = .{},
	ttl: u8 = 64,
	protocol: Protocol,
	checksum: u16 = 0,
	srcAddr: Address,
	dstAddr: Address,

	fn hton( self: *Header ) void {
		self.id = net.util.hton( self.id );
		self.flags = net.util.hton( self.flags );
	}
};

pub const Body = net.util.NetBody;

pub const Packet = struct {
	header: Header,
	body: Body,

	pub fn hton( self: *Packet ) void {
		self.header.hton();
	}

	pub fn len( self: Packet ) usize {
		return @sizeOf( Header ) + self.body.len();
	}

	pub fn toHwBody( self: *Packet ) net.util.HwBody {
		self.header.len = net.util.hton( @as( u16, @truncate( self.len() ) ) );
		self.header.checksum = 0;
		self.header.checksum = net.util.checksum( @as( [*]u16, @ptrCast( &self.header ) )[0..10] );

		return .{
			.parts = .{
				@as( [*]const u8, @ptrCast( &self.header ) )[0..@sizeOf( @import( "./ipv4.zig" ).Header )]
			}
				++ self.body.parts
				++ ( .{ null } ** ( net.util.HwBody.PARTS - net.util.NetBody.PARTS - 1 ) )
		};
	}
};

pub fn recv( _: *net.Interface, data: []const u8 ) ?net.EntryL4 {
	if ( data.len < @sizeOf( Header ) ) {
		return null;
	}

	const header: *const align(1) Header = @ptrCast( data );

	var addrMatch = false;
	for ( net.interfaces.items ) |interface| {
		if ( interface.ipv4Route ) |iproute| {
			if ( iproute.srcAddress.val == header.dstAddr.val ) {
				addrMatch = true;
				break;
			}
		}
	}

	if (
		addrMatch
		and net.util.hton( header.flags ).dontFragment
		and net.util.hton( header.len ) <= data.len
	) {
		return net.EntryL4 {
			.protocol = header.protocol,
			.data = data[@sizeOf( Header )..],
			.sockaddr = .{
				.ipv4 = .{
					.address = header.srcAddr,
					.port = 0
				}
			}
		};
	}

	return null;
}

var sendId: u16 = 0;
pub fn send( protocol: Protocol, sockaddr: net.sockaddr.Ipv4, body: net.util.NetBody ) error{ NoRouteToHost }!void {
	var target = route( sockaddr.address ) orelse return error.NoRouteToHost;

	var packet = Packet {
		.header = .{
			.protocol = protocol,
			.srcAddr = target[0].ipv4Route.?.srcAddress,
			.dstAddr = sockaddr.address,
			.id = sendId
		},
		.body = body
	};

	sendId +%= 1;
	packet.hton();

	target[0].send(
		target[1],
		net.ethernet.EtherType.Ipv4,
		packet.toHwBody()
	);
}

// TODO: add proper multi-address routing
// TODO: add ARP resolution
pub fn route( addr: Address ) ?struct{ *net.Interface, net.ethernet.Address } {
	for ( net.interfaces.items ) |*interface| {
		if ( interface.ipv4Route ) |iproute| {
			if ( iproute.match( addr ) ) {
				if ( iproute.srcAddress.val == addr.val ) {
					return .{ interface, interface.device.hwAddr };
				}

				return .{ interface, net.ethernet.Address.Broadcast };
			}
		}
	}

	return null;
}

test "net.ipv4.Route.match" {
	var iproute = Route {
		.dstNetwork = Address.init( .{ 192, 168, 10, 0 } ),
		.dstMask = Mask.init( 23 ),
		.srcAddress = Address.init( .{ 192, 168, 10, 1 } )
	};

	try std.testing.expectEqual( false, iproute.match( Address.init( .{ 192, 168, 9, 10 } ) ) );
	try std.testing.expectEqual( true, iproute.match( Address.init( .{ 192, 168, 10, 10 } ) ) );
	try std.testing.expectEqual( true, iproute.match( Address.init( .{ 192, 168, 11, 10 } ) ) );
	try std.testing.expectEqual( false, iproute.match( Address.init( .{ 192, 168, 12, 10 } ) ) );
}
