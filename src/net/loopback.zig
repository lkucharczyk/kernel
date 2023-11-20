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

		self.interface.ipv4Addr = net.ipv4.Address.init( .{ 127, 0, 0, 1 } );
	}

	pub fn send( self: *Ethernet, frame: ethernet.Frame ) void {
		frame.copyTo( &self.bufFrame );

		if ( self.interface.push( frame.len() ) ) |dst| {
			dst.getHeader().* = self.bufFrame.header;
			@memcpy( dst.getBody(), self.bufFrame.body[0..frame.body.len()] );
		}
	}
};
