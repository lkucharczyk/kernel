const std = @import( "std" );
const ipv4 = @import( "./ipv4.zig" );
const net = @import( "../net.zig" );
const netUtil = @import( "./util.zig" );
const sockaddr = @import( "./sockaddr.zig" );
const vfs = @import( "../vfs.zig" );

pub const Socket = struct {
	family: sockaddr.Family,
	stype: u32,
	protocol: ipv4.Protocol,

	node: vfs.Node = undefined,

	pub fn init( self: *Socket ) void {
		self.node.init( 1, "socket", .Socket, self, .{
			.close = &deinit
		} );
	}

	pub fn deinit( node: *vfs.Node ) void {
		var self: *Socket = @alignCast( @ptrCast( node.ctx ) );
		net.destroySocket( self );
	}

	pub fn sendto( self: *Socket, addr: sockaddr.Sockaddr, buf: []const u8 ) isize {
		if ( addr.unknown.family != self.family ) {
			return -1;
		}

		return switch ( self.protocol ) {
			.Udp => _: {
				@import( "./udp.zig" ).send( addr, buf );
				break :_ @bitCast( buf.len );
			},
			else => -1
		};
	}
};
