const std = @import( "std" );
const root = @import( "root" );
const task = @import( "./task.zig" );
const vfs = @import( "./vfs.zig" );
const x86 = @import( "./x86.zig" );
const ksyscall = @import( "./syscall.zig" ).handlerWrapper;

pub const arp = @import( "./net/arp.zig" );
pub const ethernet = @import( "./net/ethernet.zig" );
pub const ipv4 = @import( "./net/ipv4.zig" );
pub const loopback = @import( "./net/loopback.zig" );
pub const sockaddr = @import( "./net/sockaddr.zig" );
pub const udp = @import( "./net/udp.zig" );
pub const util = @import( "./net/util.zig" );

pub const Device = @import( "./net/device.zig" ).Device;
pub const Interface = @import( "./net/interface.zig" ).Interface;
pub const Socket = @import( "./net/socket.zig" ).Socket;
pub const Sockaddr = sockaddr.Sockaddr;

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

pub fn createSocket(
	family: sockaddr.Family, flags: u32, protocol: ipv4.Protocol
) error{ AddressFamilyNotSupported, InvalidArgument, ProtocolNotSupported, OutOfMemory }!*vfs.Node {
	var stype = Socket.Type.getType( flags ) orelse return error.InvalidArgument;

	if ( family != .Ipv4 ) {
		return error.AddressFamilyNotSupported;
	}

	if ( stype != .Datagram or protocol != .Udp ) {
		return error.ProtocolNotSupported;
	}

	var ptr = try sockets.create();
	ptr.family = family;
	ptr.stype = stype;
	ptr.protocol = protocol;
	ptr.init( root.kheap );

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

fn daemon( _: usize, _: [*]const [*:0]const u8 ) callconv(.C) void {
	var pollfd = std.ArrayListUnmanaged( task.PollFd ).initCapacity( root.kheap, interfaces.items.len ) catch unreachable;
	for ( interfaces.items ) |*interface| {
		pollfd.append( root.kheap, .{
			.fd = @bitCast( task.currentTask.addFd( &interface.fsNode ) catch unreachable ),
			.reqEvents = .{ .read = true }
		} ) catch unreachable;
	}

	while ( ksyscall( .Poll, .{ @intFromPtr( pollfd.items.ptr ), pollfd.items.len, @bitCast( @as( i32, -1 ) ), undefined, undefined, undefined } ) > 0 ) {
		task.currentTask.park( .{ .poll = .{ .fd = pollfd.items } } );

		for ( interfaces.items ) |*interface| {
			while ( interface.pop() ) |frame| {
				x86.disableInterrupts();
				recv( interface, frame );
				x86.enableInterrupts();
			}
		}
	}
}

pub fn recv( interface: *Interface, frame: *align(2) ethernet.FrameOpaque ) void {
	// root.log.printUnsafe( "frame: {}\n", .{ frame } );

	if (
		switch ( frame.getHeader().protocol ) {
			.Arp => arp.recv( interface, frame.getBody() ),
			.Ipv4 => ipv4.recv( interface, frame.getBody() ),
			.Ipv6 => null,
			else => _: {
				root.log.printUnsafe( "[net.recv] Unsupported EtherType: {}\n", .{ frame.getHeader().protocol } );
				break :_ null;
			}
		}
	) |entryL4| {
		switch ( entryL4.protocol ) {
			.Icmp => @import( "./net/icmp.zig" ).recv( entryL4 ),
			.Udp => @import( "./net/udp.zig" ).recv( entryL4 ),
			else => {
				root.log.printUnsafe( "[net.recv] Unsupported IpProto: {}\n", .{ entryL4.protocol } );
			}
		}
	}

	interface.allocator.free( frame.getBuffer() );
}

pub fn send( protocol: ipv4.Protocol, addr: Sockaddr, body: util.NetBody ) void {
	switch ( addr.unknown.family ) {
		.Ipv4 => ipv4.send( protocol, addr.ipv4, body ),
		else => root.log.printUnsafe(
			"[net.send] Unsupported address family: {}\n",
			.{ addr.unknown.family }
		)
	}
}
