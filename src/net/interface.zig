const std = @import( "std" );
const root = @import( "root" );
const arp = @import( "./arp.zig" );
const ethernet = @import( "./ethernet.zig" );
const icmp = @import( "./icmp.zig" );
const ipv4 = @import( "./ipv4.zig" );
const net = @import( "../net.zig" );
const netUtil = @import( "./util.zig" );
const Device = @import( "./device.zig" ).Device;

var subnet: u8 = 100;
pub const Interface = struct {
	arena: std.heap.ArenaAllocator,
	allocator: std.mem.Allocator,
	device: Device,

	rxQueue: std.DoublyLinkedList( ethernet.Frame ) = .{},
	rxQueueLimit: usize = 8,
	rxFramePool: std.heap.MemoryPoolExtra( std.DoublyLinkedList( ethernet.Frame ).Node, .{} ),

	ipv4Addr: ?ipv4.Address = null,

	pub fn init( self: *Interface, allocator: std.mem.Allocator ) void {
		self.arena = std.heap.ArenaAllocator.init( allocator );
		self.allocator = self.arena.allocator();

		self.rxQueue = .{};
		self.rxQueueLimit = 8;
		self.rxFramePool = std.heap.MemoryPoolExtra( std.DoublyLinkedList( ethernet.Frame ).Node, .{} )
			.initPreheated( allocator, self.rxQueueLimit )
			catch unreachable;

		self.ipv4Addr = ipv4.Address.init( .{ 192, 168, subnet, 2 } );
		subnet += 1;
	}

	pub fn deinit( self: *Interface ) void {
		self.arena.deinit();
		self.rxFramePool.deinit();
		self.rxQueueLimit = 0;
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

	pub fn recv( self: *Interface ) ?*ethernet.Frame {
		if ( self.rxQueue.len < self.rxQueueLimit ) {
			var node = self.rxFramePool.create() catch unreachable;
			self.rxQueue.append( node );
			net.netTask.status = .Active;
			return &node.data;
		} else {
			root.log.printUnsafe( "Interface dropped frame!\n", .{} );
		}

		return null;
	}

	pub fn process( self: *Interface ) void {
		while ( self.rxQueue.popFirst() ) |node| {
			var frame = node.data;
			// root.log.printUnsafe( "frame: {}\n", .{ frame } );

			var parts: usize = 0;
			for ( frame.body.parts ) |mpart| {
				if ( mpart != null ) {
					parts += 1;
				}
			}
			std.debug.assert( parts == 1 );

			net.recv( self, frame.header.protocol, frame.body.parts[0].? );

			for ( frame.body.parts ) |mpart| {
				if ( mpart ) |part| {
					self.allocator.free( part );
				}
			}

			self.rxFramePool.destroy( node );
		}
	}
};
