const net = @import( "../net.zig" );

pub const Header = extern struct {
	srcPort: u16,
	dstPort: u16,
	len: u16 = 0,
	checksum: u16 = 0
};

pub const Body = ?[]const u8;

pub const Datagram = struct {
	header: Header,
	body: Body,

	pub fn hton( self: *Datagram ) void {
		self.header.srcPort = net.util.hton( self.header.srcPort );
		self.header.dstPort = net.util.hton( self.header.dstPort );
	}

	pub fn len( self: Datagram ) u16 {
		return @truncate( @sizeOf( Header ) + ( if ( self.body ) |body| body.len else 0 ) );
	}

	pub fn toNetBody( self: *Datagram ) net.util.NetBody {
		self.header.len = net.util.hton( self.len() );
		self.header.checksum = 0;

		return .{
			.parts = .{
				@as( [*]const u8, @ptrCast( &self.header ) )[0..@sizeOf( Header )],
				self.body
			}
				++ ( .{ null } ** ( net.util.NetBody.PARTS - 2 ) )
		};
	}
};

pub fn initSocket( socket: *net.Socket ) void {
	socket.vtable = .{
		.bind = &bind,
		.close = &close,
		.send = &send
	};
}

fn close( socket: *net.Socket ) void {
	const port = socket.address.getPort();
	if ( port != 0 and ports[port] == socket ) {
		ports[port] = null;
	}
}

const PORTS_AUTO_START = 1024;
var ports: [0xffff]?*net.Socket = .{ null } ** 0xffff;
var portCounter: u16 = PORTS_AUTO_START - 1;
pub fn bind( socket: *net.Socket, sockaddr: ?net.Sockaddr ) error{ AddressInUse }!void {
	const port = _: {
		if ( sockaddr ) |a| {
			const port = a.getPort();
			if ( port > 0 ) {
				if ( ports[port] == null ) {
					break :_ port;
				} else {
					return error.AddressInUse;
				}
			}
		}

		for ( 0..( 0xffff - PORTS_AUTO_START ) ) |_| {
			portCounter +%= 1;
			if ( portCounter == 0 ) {
				portCounter = PORTS_AUTO_START;
			}

			if ( ports[portCounter] == null ) {
				break :_ portCounter;
			}
		}

		return error.AddressInUse;
	};

	if ( sockaddr ) |a| {
		socket.address = a;
	}
	socket.address.setPort( port );
	ports[port] = socket;
}

pub fn send( socket: ?*net.Socket, sockaddr: net.Sockaddr, body: []const u8 ) error{ NoRouteToHost }!void {
	var srcPort: u16 = 0;
	if ( socket ) |s| {
		srcPort = s.address.getPort();

		if ( srcPort == 0 ) {
			bind( s, null ) catch unreachable;
			srcPort = s.address.getPort();
		}

		if ( srcPort == 0 or ports[srcPort] != socket ) {
			@panic( "Invalid socket port" );
		}
	}

	var datagram = Datagram {
		.header = .{
			.srcPort = srcPort,
			.dstPort = sockaddr.getPort()
		},
		.body = body
	};

	datagram.hton();

	try net.send( .Udp, sockaddr, datagram.toNetBody() );
}

pub fn recv( entry: net.EntryL4 ) void {
	if ( entry.data.len < @sizeOf( Header ) ) {
		return;
	}

	const header: *const align(1) Header = @ptrCast( entry.data );
	if ( ports[net.util.hton( header.dstPort )] ) |port| {
		var addr = entry.sockaddr;
		addr.setPortNet( header.srcPort );
		port.internalRecv( addr, entry.data[@sizeOf( Header )..] );
	}
}
