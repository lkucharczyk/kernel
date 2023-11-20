const std = @import( "std" );
const root = @import( "root" );
const ethernet = @import( "./ethernet.zig" );
const ipv4 = @import( "./ipv4.zig" );
const net = @import( "../net.zig" );
const vfs = @import( "../vfs.zig" );
const Device = @import( "./device.zig" ).Device;
const RingBuffer = @import( "../util/ringBuffer.zig" ).RingBuffer;

var subnet: u8 = 100;
pub const Interface = struct {
	arena: std.heap.ArenaAllocator,
	allocator: std.mem.Allocator,
	device: Device,

	fsNode: vfs.Node = undefined,
	rxQueue: RingBuffer( *align(2) ethernet.FrameOpaque, 8 ),

	ipv4Addr: ?ipv4.Address = null,

	pub fn init( self: *Interface, allocator: std.mem.Allocator ) void {
		self.arena = std.heap.ArenaAllocator.init( allocator );
		self.allocator = self.arena.allocator();

		self.rxQueue = .{};

		self.ipv4Addr = ipv4.Address.init( .{ 192, 168, subnet, 2 } );
		subnet += 1;

		self.fsNode.init( subnet - 101, &[4:0]u8 { 'n', 'e', 't', '0' + ( subnet - 101 ) }, .Unknown, self, .{} );
		vfs.devNode.link( &self.fsNode ) catch unreachable;
	}

	pub fn deinit( self: *Interface ) void {
		self.arena.deinit();
		self.rxQueue.deinit();
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

	pub fn push( self: *Interface, len: u16 ) ?*align(2) ethernet.FrameOpaque {
		const buf = self.allocator.alignedAlloc( u8, 2, len + 2 ) catch unreachable;
		errdefer self.allocator.free( buf );

		const frame: *align(2) ethernet.FrameOpaque = @ptrCast( buf.ptr );
		if ( self.rxQueue.push( frame ) ) {
			self.fsNode.signal( .{ .read = true } );
			frame.getBodyLen().* = len - @sizeOf( ethernet.Header );
			return frame;
		} else {
			root.log.printUnsafe( "Interface dropped frame!\n", .{} );
			self.allocator.free( buf );
		}

		return null;
	}

	pub fn pop( self: *Interface ) ?*align(2) ethernet.FrameOpaque {
		if ( self.rxQueue.pop() ) |frame| {
			if ( self.rxQueue.isEmpty() ) {
				self.fsNode.signal( .{ .read = false } );
			}

			return frame;
		}

		self.fsNode.signal( .{ .read = false } );
		return null;
	}
};
