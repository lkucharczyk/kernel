const std = @import( "std" );
const ipv4 = @import( "./ipv4.zig" );
const net = @import( "../net.zig" );
const netUtil = @import( "./util.zig" );
const udp = @import( "./udp.zig" );
const sockaddr = @import( "./sockaddr.zig" );
const task = @import( "../task.zig" );
const vfs = @import( "../vfs.zig" );
const Queue = @import( "../util/queue.zig" ).Queue;

pub const Message = struct {
	srcAddr: sockaddr.Sockaddr align(4),
	data: []const u8
};

pub const Socket = struct {
	pub const Type = enum(u32) {
		Stream   = 1,
		Datagram = 2,

		pub fn getType( flags: u32 ) ?Type {
			return switch ( flags & 0x0f ) {
				1 => .Stream,
				2 => .Datagram,
				else => null
			};
		}
	};

	family: sockaddr.Family,
	stype: Type,
	protocol: ipv4.Protocol,

	address: sockaddr.Sockaddr align(4),
	node: vfs.Node = undefined,

	arena: std.heap.ArenaAllocator,
	alloc: std.mem.Allocator,
	rxQueue: Queue( Message ),

	pub fn init( self: *Socket, alloc: std.mem.Allocator ) void {
		self.arena = std.heap.ArenaAllocator.init( alloc );
		self.alloc = self.arena.allocator();
		self.rxQueue = Queue( Message ).init( alloc, 16 ) catch unreachable;

		self.address = .{ .ipv4 = .{} };
		self.node.init( 1, "socket", .Socket, self, .{
			.close = &deinit
		} );
	}

	pub fn deinit( node: *vfs.Node ) void {
		var self: *Socket = @alignCast( @ptrCast( node.ctx ) );

		var port = net.util.hton( u16, self.address.getPort() );
		if ( port != 0 and self.protocol == .Udp ) {
			udp.ports[port] = null;
		}

		self.arena.deinit();
		self.rxQueue.deinit();

		net.destroySocket( self );
	}

	pub fn bind( self: *Socket, addr: sockaddr.Sockaddr ) error{ AddressInUse, InvalidArgument }!void {
		if ( self.family != addr.unknown.family ) {
			return task.Error.InvalidArgument;
		}

		return switch ( self.protocol ) {
			.Udp => udp.bind( self, addr ),
			else => task.Error.InvalidArgument
		};
	}

	pub fn internalRecv( self: *Socket, addr: sockaddr.Sockaddr, buf: []const u8 ) void {
		if (
			self.rxQueue.push( Message {
				.data = self.alloc.dupe( u8, buf ) catch unreachable,
				.srcAddr = addr
			} ) catch unreachable
		) {
			self.node.signal();
		} else {
			@import( "root" ).log.printUnsafe( "Socket dropped frame!\n", .{} );
		}
	}

	pub fn recvfrom( self: *Socket, fd: ?*vfs.FileDescriptor ) Message {
		while ( true ) {
			if ( self.rxQueue.pop() ) |msg| {
				return msg;
			}

			if ( fd ) |wfd| {
				task.currentTask.park( .{ .fd = wfd } );
			} else {
				asm volatile ( "hlt" );
			}
		}
	}

	pub fn sendto( self: *Socket, addr: sockaddr.Sockaddr, buf: []const u8 ) error{ InvalidArgument }!isize {
		if ( addr.unknown.family != self.family ) {
			return task.Error.InvalidArgument;
		}

		return switch ( self.protocol ) {
			.Udp => _: {
				udp.send( self, addr, buf );
				break :_ @bitCast( buf.len );
			},
			else => task.Error.InvalidArgument
		};
	}
};
