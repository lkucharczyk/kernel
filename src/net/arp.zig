const std = @import( "std" );
const ethernet = @import( "./ethernet.zig" );
const ipv4 = @import( "./ipv4.zig" );

const isLe = @import( "builtin" ).cpu.arch.endian() == .Little;

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
	proto: ethernet.EtherType = .Ipv4,
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
		srcHwAddr: ethernet.Address,
		srcProtoAddr: ipv4.Address align(1),
		dstHwAddr: ethernet.Address align(1),
		dstProtoAddr: ipv4.Address align(1),

		pub fn format( self: EthIpv4, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) !void {
			try std.fmt.format( writer, "{s}{{ ( {}, {} ) -> ( {}, ", .{
				@typeName( EthIpv4 ),
				self.srcProtoAddr,
				self.srcHwAddr,
				self.dstProtoAddr
			} );

			if ( self.dstHwAddr.eq( ethernet.Address.Empty ) or self.dstHwAddr.eq( ethernet.Address.Broadcast ) ) {
				try std.fmt.format( writer, "??:??:??:??:??:?? ) }}", .{} );
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

	pub fn format( self: Packet, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) !void {
		try std.fmt.format( writer, "{s}{{ {}, ", .{ @typeName( Packet ), self.header } );
		switch ( self.header.hwType ) {
			.Ethernet => switch ( self.header.proto ) {
				.Ipv4 => try std.fmt.format( writer, "{}", .{ self.body.eth_ipv4 } ),
				else  => try std.fmt.format( writer, "{}", .{ self.body          } ),
			},
			else => try std.fmt.format( writer, "{}", .{ self.body } ),
		}
		try std.fmt.format( writer, "}}", .{} );
	}
};
