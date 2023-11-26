const std = @import( "std" );

const isLe = @import( "builtin" ).cpu.arch.endian() == .little;

pub const EtherType = enum(u16) {
	Ipv4 = if ( isLe ) ( 0x0008 ) else ( 0x0800 ),
	Ipv6 = if ( isLe ) ( 0xdd86 ) else ( 0x86dd ),
	Arp  = if ( isLe ) ( 0x0608 ) else ( 0x0806 ),
	_
};

pub const Address = extern struct {
	pub const Empty = Address.init( .{ 0x00 } ** 6 );
	pub const Broadcast = Address.init( .{ 0xff } ** 6 );

	vendor: [3]u8,
	device: [3]u8,

	pub fn init( o: [6]u8 ) Address {
		return .{
			.vendor = .{ o[0], o[1], o[2] },
			.device = .{ o[3], o[4], o[5] }
		};
	}

	pub fn eq( self: Address, other: Address ) bool {
		return self.vendor[0] == other.vendor[0]
			and self.vendor[1] == other.vendor[1]
			and self.vendor[2] == other.vendor[2]
			and self.device[0] == other.device[0]
			and self.device[1] == other.device[1]
			and self.device[2] == other.device[2];
	}

	pub fn format( self: Address, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) !void {
		try std.fmt.format( writer, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
			self.vendor[0], self.vendor[1], self.vendor[2],
			self.device[0], self.device[1], self.device[2]
		} );
	}
};

pub const Header = extern struct {
	dest: Address = Address.Broadcast,
	src: Address = Address.Broadcast,
	protocol: EtherType,

	pub fn format( self: Header, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) !void {
		try std.fmt.format( writer, "{s}{{ {} -> {}, {} }}", .{
			@typeName( Header ),
			self.src,
			self.dest,
			self.protocol
		} );
	}
};

pub const Body = @import( "./util.zig" ).HwBody;

pub const Frame = struct {
	pub const MIN_LENGTH = 0x040;
	pub const MAX_LENGTH = 0x600;

	header: Header,
	body: Body,

	pub fn len( self: Frame ) u16 {
		const out: usize = @sizeOf( Header ) + self.body.len();

		std.debug.assert( out <= MAX_LENGTH );
		return @truncate( out );
	}

	pub fn copyTo( self: Frame, dest: *FrameStatic ) void {
		dest.header = self.header;
		dest.len = self.len();

		self.body.copyTo( &dest.body );

		// const blen = dest.len - @sizeOf( Header );
		// if ( dest.len < Frame.MIN_LENGTH ) {
		// 	@memset( dest.body[blen..Frame.MIN_LENGTH - @sizeOf( Header )], 0 );
		// 	dest.len = Frame.MIN_LENGTH;
		// }
	}
};

pub const FrameStatic = extern struct {
	len: u16,
	header: Header,
	body: [Frame.MAX_LENGTH - @sizeOf( Header )]u8,

	pub fn getDmaAddress( self: *const FrameStatic ) usize {
		return @intFromPtr( self ) + @offsetOf( FrameStatic, "header" ) - @import( "../mem.zig" ).ADDR_KMAIN_OFFSET;
	}
};

pub const FrameOpaque = opaque {
	pub inline fn getHeader( self: *align(2) FrameOpaque ) *Header {
		return @ptrCast( @as( [*]u16, @ptrCast( self ) ) + 1 );
	}

	pub inline fn getBody( self: *align(2) FrameOpaque ) []align(2) u8 {
		const offset = @sizeOf( u16 ) + @sizeOf( Header );
		std.debug.assert( offset % 2 == 0 );
		return @as( [*]align(2) u8, @ptrCast( self ) )[offset..( offset + self.getBodyLen().* )];
	}

	pub inline fn getBodyLen( self: *align(2) FrameOpaque ) *u16 {
		return @ptrCast( self );
	}

	pub inline fn getBuffer( self: *align(2) FrameOpaque ) []align(2) u8 {
		return @as( [*]align(2) u8, @ptrCast( self ) )[0..( @sizeOf( u16 ) + @sizeOf( Header ) + self.getBodyLen().* )];
	}
};
