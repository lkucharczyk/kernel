const std = @import( "std" );

pub fn Queue( comptime T: type ) type {
	return struct {
		const Self = @This();

		list: std.DoublyLinkedList( T ),
		pool: std.heap.MemoryPoolExtra( std.DoublyLinkedList( T ).Node, .{} ),
		limit: usize,

		pub fn init( alloc: std.mem.Allocator, limit: usize ) std.mem.Allocator.Error!Self {
			return .{
				.list = .{},
				.pool = try std.heap.MemoryPoolExtra( std.DoublyLinkedList( T ).Node, .{} ).initPreheated( alloc, limit ),
				.limit = limit
			};
		}

		pub fn deinit( self: *Self ) void {
			self.pool.deinit();
		}

		pub fn push( self: *Self, item: T ) std.mem.Allocator.Error!bool {
			if ( self.list.len < self.limit ) {
				var node = try self.pool.create();
				node.data = item;
				self.list.append( node );
				return true;
			}

			return false;
		}

		pub fn pop( self: *Self ) ?T {
			if ( self.list.popFirst() ) |node| {
				const out = node.data;
				self.pool.destroy( node );
				return out;
			}

			return null;
		}

		pub inline fn isEmpty( self: Self ) bool {
			return self.list.len == 0;
		}
	};
}
