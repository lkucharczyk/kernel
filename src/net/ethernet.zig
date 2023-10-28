const std = @import( "std" );

const isLe = @import( "builtin" ).cpu.arch.endian() == .Little;

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

pub const Body = extern union {
	arp: *@import( "./arp.zig" ).Packet,
	raw: extern struct {
		ptr: [*]u8,
		len: usize,

		pub fn asPtr( self: @This() ) []u8 {
			var out: []u8 = undefined;
			out.ptr = self.ptr;
			out.len = self.len;
			return out;
		}
	}
};

pub const Frame = struct {
	pub const MIN_LENGTH = 0x040;
	pub const MAX_LENGTH = 0x600;

	header: Header,
	body: Body,

	pub fn len( self: Frame ) usize {
		const out: usize = @sizeOf( Header ) + switch ( self.header.protocol ) {
			.Arp => self.body.arp.len(),
			// .ipv4 => |b| b.len(),
			else => self.body.raw.len
		};

		std.debug.assert( out <= MAX_LENGTH );
		return @truncate( out );
	}

	pub fn copyTo( self: Frame, dest: *FrameStatic ) void {
		dest.header = self.header;
		dest.len = self.len();

		const blen = dest.len - @sizeOf( Header );
		@memcpy( dest.body[0..blen], self.body.raw.ptr[0..blen] );

		if ( dest.len < Frame.MIN_LENGTH ) {
			@memset( dest.body[blen..Frame.MIN_LENGTH - @sizeOf( Header )], 0 );
			dest.len = Frame.MIN_LENGTH;
		}
	}
};

pub const FrameStatic = extern struct {
	header: Header,
	body: [Frame.MAX_LENGTH - @sizeOf( Header )]u8,
	len: usize
};
