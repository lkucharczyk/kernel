const root = @import( "root" );
const arp = @import( "./arp.zig" );
const ethernet = @import( "./ethernet.zig" );
const ipv4 = @import( "./ipv4.zig" );
const Device = @import( "./device.zig" ).Device;

var subnet: u8 = 1;
pub const Interface = struct {
	device: Device,

	ipv4Addr: ?ipv4.Address = null,

	pub fn init( self: *Interface ) void {
		self.ipv4Addr = ipv4.Address.init( .{ 192, 168, subnet, 2 } );
		subnet += 1;
	}

	pub fn send( self: Interface, dest: ethernet.Address, proto: ethernet.EtherType, body: ethernet.Body ) void {
		self.device.send( ethernet.Frame {
			.header = .{
				.dest = dest,
				.protocol = proto
			},
			.body = body
		} );
	}

	pub fn recv( self: Interface, frame: ethernet.Frame ) void {
		if ( frame.header.protocol == .Arp ) {
			const arpPacket = frame.body.arp;

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

				self.send( frame.header.src, .Arp, ethernet.Body { .arp = &arpRequest } );
			}
		}

		root.kheap.free( frame.body.raw.asPtr() );
	}
};
