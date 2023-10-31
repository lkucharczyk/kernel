const std = @import( "std" );
const netUtil = @import( "./util.zig" );

pub const Address = packed struct(u32) {
	val: u32,

	pub inline fn init( o: [4]u8 ) Address {
		return .{
			.val =
				(   @as( u32, @intCast( o[3] ) ) << 24 )
				| ( @as( u32, @intCast( o[2] ) ) << 16 )
				| ( @as( u32, @intCast( o[1] ) ) <<  8 )
				| ( @as( u32, @intCast( o[0] ) ) <<  0 )
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

pub const Protocol = enum(u8) {
	Icmp =  1,
	Tcp  =  6,
	Udp  = 17,
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
		self.id = netUtil.hton( u16, self.id );
		self.flags = netUtil.hton( Flags, self.flags );
	}
};

pub const Body = netUtil.NetBody;

pub const Packet = struct {
	header: Header,
	body: Body,

	pub fn hton( self: *Packet ) void {
		self.header.hton();
	}

	pub fn len( self: Packet ) usize {
		return @sizeOf( Header ) + self.body.len();
	}

	pub fn toHwBody( self: *Packet ) netUtil.HwBody {
		self.header.len = netUtil.hton( u16, @truncate( self.len() ) );
		self.header.checksum = 0;
		self.header.checksum = netUtil.checksum( @as( [*]u16, @ptrCast( &self.header ) )[0..10] );

		return .{
			.parts = .{
				@as( [*]const u8, @ptrCast( &self.header ) )[0..@sizeOf( @import( "./ipv4.zig" ).Header )]
			}
				++ self.body.parts
				++ ( .{ null } ** ( netUtil.HwBody.PARTS - netUtil.NetBody.PARTS - 1 ) )
		};
	}
};
