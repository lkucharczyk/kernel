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

		if ( self.interface.recv() ) |dst| {
			dst.header = self.bufFrame.header;
			var mbuf: ?[]u8 = self.interface.allocator.alloc( u8, self.bufFrame.len - @sizeOf( ethernet.Header ) ) catch null;

			if ( mbuf ) |buf| {
				@memcpy( buf, self.bufFrame.body[0..buf.len] );
				dst.body = ethernet.Body.init( buf );
			} else {
				dst.body = ethernet.Body.init( "" );
			}
		}
	}
};
