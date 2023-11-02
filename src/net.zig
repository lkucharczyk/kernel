const std = @import( "std" );
const root = @import( "root" );
const task = @import( "./task.zig" );
const vfs = @import( "./vfs.zig" );
const x86 = @import( "./x86.zig" );

pub const ethernet = @import( "./net/ethernet.zig" );
pub const ipv4 = @import( "./net/ipv4.zig" );
pub const loopback = @import( "./net/loopback.zig" );
pub const util = @import( "./net/util.zig" );

pub const Device = @import( "./net/device.zig" ).Device;
pub const Interface = @import( "./net/interface.zig" ).Interface;
pub const Socket = @import( "./net/socket.zig" ).Socket;
pub const Sockaddr = @import( "./net/sockaddr.zig" ).Sockaddr;

pub const EntryL4 = struct {
	protocol: ipv4.Protocol,
	sockaddr: Sockaddr,
	data: []const u8
};

pub var interfaces = std.ArrayListUnmanaged( Interface ) {};
pub var sockets: std.heap.MemoryPoolExtra( Socket, .{} ) = undefined;
pub var netTask: *task.Task = undefined;

var loEthernet: loopback.Ethernet = undefined;

pub fn createInterface( device: Device ) *Interface {
	var ptr = interfaces.addOne( root.kheap ) catch unreachable;

	ptr.device = device;
	ptr.init( root.kheap );

	return ptr;
}

pub fn createSocket() *vfs.Node {
	var ptr = sockets.create() catch unreachable;
	ptr.family = .Ipv4;
	ptr.protocol = .Udp;
	ptr.stype = std.os.linux.SOCK.DGRAM;
	ptr.init();
	return &ptr.node;
}

pub fn destroySocket( socket: *Socket ) void {
	sockets.destroy( socket );
}

pub fn init() std.mem.Allocator.Error!void {
	sockets = std.heap.MemoryPoolExtra( Socket, .{} ).init( root.kheap );
	loEthernet.init();
	netTask = task.create( daemon, true );
}

fn daemon() void {
	while ( true ) {
		for ( interfaces.items ) |*interface| {
			interface.process();
		}

		x86.disableInterrupts();
		var park: bool = true;
		for ( interfaces.items ) |*interface| {
			if ( interface.rxQueue.len > 0 ) {
				park = false;
				break;
			}
		}

		if ( park ) {
			netTask.park();
		}
		x86.enableInterrupts();
	}
}

pub fn recv( interface: *Interface, etherType: ethernet.EtherType, data: []const u8 ) void {
	if (
		switch ( etherType ) {
			.Arp => @import( "./net/arp.zig" ).recv( interface, data ),
			.Ipv4 => ipv4.recv( interface, data ),
			.Ipv6 => return,
			else => {
				root.log.printUnsafe( "[net.recv] Unsupported EtherType: {}\n", .{ etherType } );
				return;
			}
		}
	) |entryL4| {
		switch ( entryL4.protocol ) {
			.Icmp => @import( "./net/icmp.zig" ).recv( entryL4 ),
			else => {
				root.log.printUnsafe( "[net.recv] Unsupported IpProto: {}\n", .{ entryL4.protocol } );
				return;
			}
		}
	}
}

pub fn send( protocol: ipv4.Protocol, sockaddr: Sockaddr, body: util.NetBody ) void {
	switch ( sockaddr.unknown.family ) {
		.Ipv4 => ipv4.send( protocol, sockaddr.ipv4, body ),
		else => root.log.printUnsafe(
			"[net.send] Unsupported address family: {}\n",
			.{ sockaddr.unknown.family }
		)
	}
}
