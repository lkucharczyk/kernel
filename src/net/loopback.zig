const std = @import( "std" );
const ethernet = @import( "./ethernet.zig" );
const Device = @import( "./device.zig" ).Device;
const Interface = @import( "./interface.zig" ).Interface;

pub const Ethernet = struct {
	interface: *Interface,
	bufFrame: ethernet.FrameStatic = undefined,

	pub fn init( self: *Ethernet ) void {
		self.interface = @import( "../net.zig" ).createInterface( Device {
			.hwAddr = ethernet.Address.Empty,
			.context = self,
			.vtable = .{
				.send = @ptrCast( &send )
			}
		} );

		self.interface.ipv4Addr = @import( "./ipv4.zig" ).Address.init( .{ 127, 0, 0, 1 } );
	}

	pub fn send( self: *Ethernet, frame: ethernet.Frame ) void {
		frame.copyTo( &self.bufFrame );

		if ( self.interface.recv() ) |dst| {
			dst.header = self.bufFrame.header;
			var mbuf: ?[]u8 = self.interface.allocator.alloc( u8, self.bufFrame.len - @sizeOf( ethernet.Header ) ) catch null;

			if ( mbuf ) |buf| {
				dst.body = ethernet.Body.init( buf );
			} else {
				dst.body = ethernet.Body.init( "" );
			}
		}
	}
};
