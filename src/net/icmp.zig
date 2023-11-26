const std = @import( "std" );
const root = @import( "root" );
const net = @import( "../net.zig" );
const netUtil = @import( "./util.zig" );

pub const Type = enum(u8) {
	EchoReply   = 0,
	EchoRequest = 8,
	_
};

pub const HeaderData = extern union {
	echo: extern struct {
		identifier: u16,
		sequence: u16
	},
	raw: u32
};

pub const Header = extern struct {
	dtype: Type,
	subtype: u8 = 0,
	checksum: u16 = 0,
	data: HeaderData = .{ .raw = 0 }
};

pub const Body = ?[]const u8;

pub const Datagram = struct {
	header: Header,
	body: Body,

	pub fn len( self: Datagram ) usize {
		return @sizeOf( Header ) + self.body.len;
	}

	pub fn toNetBody( self: *Datagram ) netUtil.NetBody {
		self.header.checksum = 0;
		self.header.checksum = if ( self.body ) |body| (
			netUtil.checksumBody(
				~netUtil.checksum( @as( [*]u16, @ptrCast( &self.header ) )[0..4] ),
				body
			)
		) else (
			netUtil.checksum( @as( [*]u16, @ptrCast( &self.header ) )[0..4] )
		);

		return .{
			.parts = .{
				@as( [*]const u8, @ptrCast( &self.header ) )[0..@sizeOf( Header )],
				self.body
			}
				++ ( .{ null } ** ( netUtil.NetBody.PARTS - 2 ) )
		};
	}
};

pub fn recv( entry: net.EntryL4 ) void {
	if ( entry.data.len < @sizeOf( Header ) ) {
		return;
	}

	const header: *const align( 1 ) Header = @ptrCast( entry.data );
	const body: Body = entry.data[@sizeOf( Header )..];

	if ( header.dtype == .EchoRequest and header.subtype == 0 ) {
		root.log.printUnsafe( "ping req: {}\n", .{ entry.sockaddr } );

		var response = Datagram {
			.header = .{
				.dtype = .EchoReply,
				.data = .{ .raw = header.data.raw }
			},
			.body = body
		};

		net.send( .Icmp, entry.sockaddr, response.toNetBody() ) catch {};
	}
}
