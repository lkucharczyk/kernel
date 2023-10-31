const std = @import( "std" );
const root = @import( "root" );
const arp = @import( "./arp.zig" );
const ethernet = @import( "./ethernet.zig" );
const icmp = @import( "./icmp.zig" );
const ipv4 = @import( "./ipv4.zig" );
const netUtil = @import( "./util.zig" );
const Device = @import( "./device.zig" ).Device;

var subnet: u8 = 1;
pub const Interface = struct {
	allocator: std.mem.Allocator,
	device: Device,

	ipv4Addr: ?ipv4.Address = null,

	pub fn init( self: *Interface, allocator: std.mem.Allocator ) void {
		self.allocator = allocator;
		self.ipv4Addr = ipv4.Address.init( .{ 192, 168, subnet, 2 } );
		subnet += 1;
	}

	pub inline fn send( self: Interface, dest: ethernet.Address, proto: ethernet.EtherType, body: ethernet.Body ) void {
		self.device.send( ethernet.Frame {
			.header = .{
				.dest = dest,
				.protocol = proto
			},
			.body = body
		} );
	}

	pub fn recv( self: Interface, frame: ethernet.Frame ) void {
		root.log.printUnsafe( "frame: {}\n", .{ frame } );

		var parts: usize = 0;
		for ( frame.body.parts ) |mpart| {
			if ( mpart != null ) {
				parts += 1;
			}
		}
		std.debug.assert( parts == 1 );

		const data = frame.body.parts[0].?;

		if (
			frame.header.protocol == .Arp
			and data.len >= ( @sizeOf( arp.Header ) + @sizeOf( arp.Body.EthIpv4 ) )
		) {
			const arpPacket: *const align(1) arp.Packet = @ptrCast( data );

			if (
				arpPacket.header.opCode == .Request
				and arpPacket.header.hwType == .Ethernet
				and arpPacket.header.proto == .Ipv4
				and arpPacket.body.eth_ipv4.dstProtoAddr.val == self.ipv4Addr.?.val
			) {
				root.log.printUnsafe( "arp req: {}\n", .{ arpPacket } );

				var arpRequest = arp.Packet {
					.header = .{ .opCode = .Response },
					.body = .{
						.eth_ipv4 = .{
							.srcHwAddr = self.device.hwAddr,
							.dstHwAddr = arpPacket.body.eth_ipv4.srcHwAddr,
							.srcProtoAddr = self.ipv4Addr.?,
							.dstProtoAddr = arpPacket.body.eth_ipv4.srcProtoAddr
						}
					}
				};

				self.send( frame.header.src, .Arp, arpRequest.toHwBody() );
			}
		}

		if (
			frame.header.protocol == .Ipv4
			and data.len >= ( @sizeOf( ipv4.Header ) + @sizeOf( icmp.Header ) )
		) {
			const ipHeader: *const align(1) ipv4.Header = @ptrCast( data );

			if (
				ipHeader.protocol == .Icmp
				and ipHeader.dstAddr.val == self.ipv4Addr.?.val
			) {
				const icmpHeader: *const align(1) icmp.Header = @ptrCast( data[@sizeOf( ipv4.Header )..] );
				const icmpBody: []const u8 = data[( @sizeOf( ipv4.Header ) + @sizeOf( icmp.Header ) )..];

				root.log.printUnsafe( "ping: {} {}\n", .{ ipHeader.srcAddr, icmpHeader } );

				var icmpDatagram = icmp.Datagram {
					.header = .{
						.dtype = .EchoReply,
						.data = .{ .raw = icmpHeader.data.raw }
					},
					.body = icmpBody
				};

				var ipPacket = ipv4.Packet {
					.header = .{
						.srcAddr = self.ipv4Addr.?,
						.dstAddr = ipHeader.srcAddr,
						.protocol = .Icmp
					},
					.body = icmpDatagram.toNetBody()
				};

				ipPacket.hton();

				if ( icmpHeader.dtype == .EchoRequest ) {
					self.send( frame.header.src, .Ipv4, ipPacket.toHwBody() );
				}
			}
		}

		for ( frame.body.parts ) |mpart| {
			if ( mpart ) |part| {
				root.kheap.free( part );
			}
		}
	}
};
