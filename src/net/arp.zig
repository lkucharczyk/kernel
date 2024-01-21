const std = @import( "std" );
const root = @import( "root" );
const net = @import( "../net.zig" );

const isLe = @import( "builtin" ).cpu.arch.endian() == .little;

pub const HwType = enum(u16) {
	Ethernet = if ( isLe ) ( 0x0100 ) else ( 0x0001 ),
	_
};

pub const OpCode = enum(u16) {
	Request  = if ( isLe ) ( 0x0100 ) else ( 0x0001 ),
	Response = if ( isLe ) ( 0x0200 ) else ( 0x0002 ),
	_
};

pub const Header = packed struct {
	hwType: HwType = .Ethernet,
	proto: net.ethernet.EtherType = .Ipv4,
	hwAddrLen: u8 = 6,
	protoAddrLen: u8 = 4,
	opCode: OpCode = OpCode.Request,

	pub fn format( self: Header, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) !void {
		try std.fmt.format( writer, "{s}{{ {}, {} ({}B), {} ({}B) }}", .{
			@typeName( Header ),
			self.opCode,
			self.hwType,
			self.hwAddrLen,
			self.proto,
			self.protoAddrLen
		} );
	}
};

pub const Body = extern struct {
	pub const EthIpv4 = extern struct {
		srcHwAddr: net.ethernet.Address,
		srcProtoAddr: net.ipv4.Address align(1),
		dstHwAddr: net.ethernet.Address align(1),
		dstProtoAddr: net.ipv4.Address align(1),

		pub fn format( self: EthIpv4, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) !void {
			try std.fmt.format( writer, "{s}{{ ( {}, {} ) -> ( {}, ", .{
				@typeName( EthIpv4 ),
				self.srcProtoAddr,
				self.srcHwAddr,
				self.dstProtoAddr
			} );

			if ( self.dstHwAddr.eq( net.ethernet.Address.Empty ) or self.dstHwAddr.eq( net.ethernet.Address.Broadcast ) ) {
				_ = try writer.write( "??:??:??:??:??:?? ) }}" );
			} else {
				try std.fmt.format( writer, "{} ) }}", .{ self.dstHwAddr } );
			}
		}
	};

	pub fn Generic( comptime H: comptime_int, comptime P: comptime_int ) type {
		return extern struct {
			srcHwAddr: [H]u8,
			srcProtoAddr: [P]u8,
			dstHwAddr: [H]u8,
			dstProtoAddr: [P]u8,
		};
	}
};

pub const Packet = extern struct {
	header: Header,
	body: extern union {
		eth_ipv4: Body.EthIpv4
	} align(1),

	pub fn len( self: Packet ) usize {
		return @sizeOf( Header ) + self.header.hwAddrLen * 2 + self.header.protoAddrLen * 2;
	}

	pub inline fn toHwBody( self: *const Packet ) net.util.HwBody {
		return net.util.HwBody.init( @as( [*]const u8, @ptrCast( self ) )[0..self.len()] );
	}

	pub fn format( self: Packet, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) !void {
		try std.fmt.format( writer, "{s}{{ {}, ", .{ @typeName( Packet ), self.header } );
		switch ( self.header.hwType ) {
			.Ethernet => switch ( self.header.proto ) {
				.Ipv4 => try std.fmt.format( writer, "{}", .{ self.body.eth_ipv4 } ),
				else  => try std.fmt.format( writer, "{}", .{ self.body          } ),
			},
			else => try std.fmt.format( writer, "{}", .{ self.body } ),
		}
		_ = try writer.write( " }" );
	}
};

pub fn recv( interface: *net.Interface, data: []const u8 ) ?net.EntryL4 {
	if ( data.len < @sizeOf( Packet ) ) {
		return null;
	}

	const packet: *const align(1) Packet = @ptrCast( data );
	if (
		data.len < packet.len()
		and packet.header.hwType == .Ethernet
		and packet.header.proto == .Ipv4
	) {
		return null;
	}

	if (
		packet.header.opCode == .Request
		and interface.ipv4Route != null
		and interface.ipv4Route.?.srcAddress.val == packet.body.eth_ipv4.dstProtoAddr.val
	) {
		// root.log.printUnsafe( "arp req: {}\n", .{ packet } );

		var response = Packet {
			.header = .{ .opCode = .Response },
			.body = .{
				.eth_ipv4 = .{
					.srcHwAddr = interface.device.hwAddr,
					.dstHwAddr = packet.body.eth_ipv4.srcHwAddr,
					.srcProtoAddr = interface.ipv4Route.?.srcAddress,
					.dstProtoAddr = packet.body.eth_ipv4.srcProtoAddr
				}
			}
		};

		interface.ipv4Neighbours.put( packet.body.eth_ipv4.srcProtoAddr, packet.body.eth_ipv4.srcHwAddr ) catch {};
		interface.send( packet.body.eth_ipv4.srcHwAddr, .Arp, response.toHwBody() );
	} else if (
		packet.header.opCode == .Response
		and packet.body.eth_ipv4.dstHwAddr.eq( interface.device.hwAddr )
		and interface.ipv4Route != null
		and interface.ipv4Route.?.srcAddress.val == packet.body.eth_ipv4.dstProtoAddr.val
	) {
		interface.ipv4Neighbours.put( packet.body.eth_ipv4.srcProtoAddr, packet.body.eth_ipv4.srcHwAddr ) catch {};
	}

	return null;
}
