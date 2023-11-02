const net = @import( "../net.zig" );

pub const Header = extern struct {
	srcPort: u16,
	dstPort: u16,
	len: u16 = 0,
	checksum: u16 = 0
};

pub const Body = ?[]const u8;

pub const Datagram = struct {
	header: Header,
	body: Body,

	pub fn hton( self: *Datagram ) void {
		self.header.srcPort = net.util.hton( u16, self.header.srcPort );
		self.header.dstPort = net.util.hton( u16, self.header.dstPort );
	}

	pub fn len( self: Datagram ) u16 {
		return @truncate( @sizeOf( Header ) + ( if ( self.body ) |body| body.len else 0 ) );
	}

	pub fn toNetBody( self: *Datagram ) net.util.NetBody {
		self.header.len = net.util.hton( u16, self.len() );
		self.header.checksum = 0;

		return .{
			.parts = .{
				@as( [*]const u8, @ptrCast( &self.header ) )[0..@sizeOf( Header )],
				self.body
			}
				++ ( .{ null } ** ( net.util.NetBody.PARTS - 2 ) )
		};
	}
};

pub fn send( sockaddr: net.Sockaddr, body: []const u8 ) void {
	var datagram = Datagram {
		.header = .{
			.srcPort = 5000,
			.dstPort = net.util.hton( u16, sockaddr.getPort() )
		},
		.body = body
	};

	datagram.hton();

	net.send( .Udp, sockaddr, datagram.toNetBody() );
}
