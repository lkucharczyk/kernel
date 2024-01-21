const std = @import( "std" );
const root = @import( "root" );
const ethernet = @import( "./ethernet.zig" );
const ipv4 = @import( "./ipv4.zig" );
const net = @import( "../net.zig" );
const task = @import( "../task.zig" );
const vfs = @import( "../vfs.zig" );
const Device = @import( "./device.zig" ).Device;
const RingBuffer = @import( "../util/ringBuffer.zig" ).RingBuffer;

var subnet: u8 = 100;
pub const Interface = struct {
	const VTable = vfs.VTable {
		.ioctl = &ioctl
	};

	arena: std.heap.ArenaAllocator,
	allocator: std.mem.Allocator,
	device: Device,

	fsNode: vfs.Node = undefined,
	rxQueue: RingBuffer( *align(2) ethernet.FrameOpaque, 8 ),

	ipv4Route: ?ipv4.Route = null,
	ipv4Neighbours: std.AutoHashMap( net.ipv4.Address, net.ethernet.Address ),

	pub fn init( self: *Interface, allocator: std.mem.Allocator ) void {
		self.arena = std.heap.ArenaAllocator.init( allocator );
		self.allocator = self.arena.allocator();

		self.rxQueue = .{};

		self.ipv4Route = ipv4.Route {
			.srcAddress = ipv4.Address.init( .{ 192, 168, subnet, 2 } ),
			.dstNetwork = ipv4.Address.init( .{ 192, 168, subnet, 0 } ),
			.dstMask = ipv4.Mask.init( 24 ),
			.viaAddress = ipv4.Address.init( .{ 192, 168, subnet, 1 } )
		};
		self.ipv4Neighbours = std.AutoHashMap( net.ipv4.Address, net.ethernet.Address ).init( allocator );
		subnet += 1;

		self.fsNode.init( subnet - 101, .Unknown, self, .{ .ioctl = &ioctl } );
		vfs.devNode.link( &self.fsNode, &[4:0]u8 { 'n', 'e', 't', '0' + ( subnet - 101 ) } ) catch unreachable;
	}

	pub fn deinit( self: *Interface ) void {
		self.arena.deinit();
		self.rxQueue.deinit();
	}

	pub fn send( self: *Interface, dest: ethernet.Address, proto: ethernet.EtherType, body: ethernet.Body ) void {
		const frame = ethernet.Frame {
			.header = .{
				.dest = dest,
				.protocol = proto
			},
			.body = body
		};

		if ( dest.eq( self.device.hwAddr ) ) {
			if ( self.push( frame.len() ) ) |bufFrame| {
				bufFrame.getHeader().* = frame.header;
				body.copyTo( bufFrame.getBody() );
			}
		} else {
			self.device.send( frame );
		}
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

	fn ioctl( node: *vfs.Node, _: *vfs.FileDescriptor, cmd: u32, arg: usize ) task.Error!i32 {
		const self: *Interface = @alignCast( @ptrCast( node.ctx ) );

		if ( cmd == 0 ) {
			if ( arg == 0 ) {
				const stderr = try task.currentTask.getFd( 2 );
				const writer = std.io.Writer( *vfs.FileDescriptor, anyerror, vfs.FileDescriptor.write ) { .context = stderr };

				writer.print( "Ethernet:\n Address: {}\n", .{ self.device.hwAddr } ) catch {};
				writer.print( "\nIPv4:\n Route: {?}\n Neighbours:\n", .{ self.ipv4Route } ) catch {};
				if ( self.ipv4Neighbours.count() > 0 ) {
					var iter = self.ipv4Neighbours.iterator();
					while ( iter.next() ) |entry| {
						writer.print( "  - {} -> {}\n", .{ entry.key_ptr, entry.value_ptr } ) catch {};
					}
				} else {
					_ = writer.write( "  <none>\n" ) catch {};
				}

				return 0;
			}

			const ptr: *align(1) ipv4.Route = @ptrFromInt( arg );
			if ( ptr.srcAddress.val == 0 ) {
				if ( self.ipv4Route ) |route| {
					self.ipv4Neighbours.clearAndFree();
					ptr.* = route;
				}
			} else {
				self.ipv4Route = ptr.*;
			}

			return 0;
		}

		return task.Error.PermissionDenied;
	}
};
