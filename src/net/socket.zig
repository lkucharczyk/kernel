const std = @import( "std" );
const net = @import( "../net.zig" );
const task = @import( "../task.zig" );
const vfs = @import( "../vfs.zig" );
const Queue = @import( "../util/queue.zig" ).Queue;

pub const Message = struct {
	srcAddr: net.Sockaddr align(4),
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

	pub const VTable = struct {
		bind: ?*const fn( *Socket, ?net.Sockaddr ) error{ AddressInUse }!void = null,
		close: ?*const fn( *Socket ) void = null,
		send: ?*const fn( *Socket, net.Sockaddr, []const u8 ) error{ NoRouteToHost }!void = null
	};

	family: net.sockaddr.Family,
	stype: Type,
	protocol: net.ipv4.Protocol,

	address: net.Sockaddr align(4),
	node: vfs.Node = undefined,

	arena: std.heap.ArenaAllocator,
	alloc: std.mem.Allocator,
	rxQueue: Queue( Message ),

	vtable: VTable,

	pub fn init( self: *Socket, alloc: std.mem.Allocator ) void {
		self.arena = std.heap.ArenaAllocator.init( alloc );
		self.alloc = self.arena.allocator();
		self.rxQueue = Queue( Message ).init( alloc, 16 ) catch unreachable;

		self.address = .{ .ipv4 = .{} };
		self.node.init( 1, .Socket, self, .{
			.close = &deinit,
			.read = &read
		} );

		switch ( self.protocol ) {
			.Udp => net.udp.initSocket( self ),
			else => {
				self.vtable = .{};
			}
		}
	}

	pub fn deinit( node: *vfs.Node ) void {
		var self: *Socket = @alignCast( @ptrCast( node.ctx ) );

		if ( self.vtable.close ) |f| {
			f( self );
		}

		self.arena.deinit();
		self.rxQueue.deinit();

		net.destroySocket( self );
	}

	pub fn bind( self: *Socket, addr: net.Sockaddr ) error{ AddressInUse, InvalidArgument }!void {
		if ( self.family != addr.unknown.family ) {
			return task.Error.InvalidArgument;
		}

		return if ( self.vtable.bind ) |f| (
			f( self, addr )
		) else (
			task.Error.InvalidArgument
		);
	}

	pub fn internalRecv( self: *Socket, addr: net.Sockaddr, buf: []const u8 ) void {
		if (
			self.rxQueue.push( Message {
				.data = self.alloc.dupe( u8, buf ) catch unreachable,
				.srcAddr = addr
			} ) catch unreachable
		) {
			self.node.signal( .{ .read = true } );
		} else {
			@import( "root" ).log.printUnsafe( "Socket dropped frame!\n", .{} );
		}
	}

	pub fn read( node: *vfs.Node, fd: *vfs.FileDescriptor, buf: []u8 ) u32 {
		var self: *Socket = @alignCast( @ptrCast( node.ctx ) );
		const msg = self.recvfrom( fd );

		const blen = @min( msg.data.len, buf.len );
		@memcpy( buf[0..blen], msg.data[0..blen] );
		self.alloc.free( msg.data );

		return blen;
	}

	pub fn recvfrom( self: *Socket, fd: ?*vfs.FileDescriptor ) Message {
		while ( true ) {
			if ( self.rxQueue.pop() ) |msg| {
				if ( self.rxQueue.isEmpty() ) {
					self.node.signal( .{ .read = false } );
				}

				return msg;
			}

			if ( fd ) |wfd| {
				task.currentTask.park(
					.{ .fd = .{ .ptr = wfd, .status = .{ .read = true } } }
				);
			} else {
				asm volatile ( "hlt" );
			}
		}
	}

	pub fn sendto( self: *Socket, addr: net.Sockaddr, buf: []const u8 ) error{ InvalidArgument, NoRouteToHost }!isize {
		if ( addr.unknown.family != self.family ) {
			return task.Error.InvalidArgument;
		}

		if ( self.vtable.send ) |f| {
			try f( self, addr, buf );
			return @bitCast( buf.len );
		} else {
			return task.Error.InvalidArgument;
		}
	}
};
