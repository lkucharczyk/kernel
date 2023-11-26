const std = @import( "std" );
const ethernet = @import( "./ethernet.zig" );
const net = @import( "../net.zig" );

pub const Ethernet = struct {
	interface: *net.Interface,
	bufFrame: ethernet.FrameStatic = undefined,

	pub fn init( self: *Ethernet ) void {
		self.interface = net.createInterface( net.Device {
			.hwAddr = ethernet.Address.Empty,
			.context = self,
			.vtable = .{
				.send = @ptrCast( &send )
			}
		} );

		self.interface.ipv4Route = .{
			.srcAddress = net.ipv4.Address.Localhost,
			.dstNetwork = net.ipv4.Address.Localhost,
			.dstMask = net.ipv4.Mask.init( 32 ),
			.viaAddress = net.ipv4.Address.Localhost
		};
	}

	pub fn send( self: *Ethernet, frame: ethernet.Frame ) void {
		frame.copyTo( &self.bufFrame );

		if ( self.interface.push( frame.len() ) ) |dst| {
			dst.getHeader().* = self.bufFrame.header;
			@memcpy( dst.getBody(), self.bufFrame.body[0..frame.body.len()] );
		}
	}
};
