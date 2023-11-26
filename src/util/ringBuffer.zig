const std = @import( "std" );

pub fn RingBuffer( comptime T: type, comptime S: comptime_int ) type {
	return struct {
		const Self = @This();

		items: [S]?T = .{ null } ** S,
		posw: usize = 0,
		posr: usize = 0,

		pub fn pushUndefined( self: *Self ) ?*T {
			if ( self.items[self.posw] == null ) {
				self.items[self.posw] = undefined;
				const out = &self.items[self.posw].?;
				self.posw = ( self.posw + 1 ) % S;
				return out;
			}

			return null;
		}

		pub fn push( self: *Self, item: T ) bool {
			if ( self.items[self.posw] == null ) {
				self.items[self.posw] = item;
				self.posw = ( self.posw + 1 ) % S;
				return true;
			}

			return false;
		}

		pub fn peek( self: *Self ) ?*T {
			if ( self.items[self.posr] ) |*item| {
				return item;
			}

			return null;
		}

		pub fn pop( self: *Self ) ?T {
			if ( self.items[self.posr] ) |item| {
				self.items[self.posr] = null;
				self.posr = ( self.posr + 1 ) % S;
				return item;
			}

			return null;
		}

		pub fn isEmpty( self: Self ) bool {
			return self.items[self.posr] == null;
		}
	};
}

pub fn RingBufferExt( comptime S: comptime_int, comptime P: comptime_int ) type {
	return struct {
		const Self = @This();

		data: [S]u8 = undefined,
		pad: [P]u8 = undefined,
		pos: usize = 0,

		pub fn read( self: *Self, comptime T: type ) T {
			var out: T = undefined;
			self.readBytes( @as( [*]u8, @ptrCast( &out ) )[0..@sizeOf( T )] );
			return out;
		}

		pub fn readBytes( self: *Self, buf: []u8 ) void {
			std.debug.assert( buf.len <= S );

			if ( self.pos + buf.len < S ) {
				@memcpy( buf, self.data[self.pos..( self.pos + buf.len )] );
				// @memset( self.data[self.pos..( self.pos + buf.len )], 0 );
				self.pos += buf.len;
			} else {
				const s1: usize = S - self.pos;
				const s2: usize = buf.len - s1;

				@memcpy( buf[0..s1], self.data[self.pos..S] );
				// @memset( self.data[self.pos..S], 0 );
				@memcpy( buf[s1..buf.len], self.data[0..s2] );
				// @memset( self.data[0..s2], 0 );
				self.pos = s2;
			}
		}

		pub fn seek( self: *Self, offset: isize ) void {
			if ( offset >= 0 ) {
				self.pos = ( self.pos + @as( usize, @bitCast( offset ) ) ) % S;
			} else if ( -offset <= self.pos ) {
				self.pos -= @as( usize, @bitCast( -offset ) );
			} else {
				self.pos = S - ( @as( usize, @bitCast( -offset ) ) - self.pos );
			}
		}
	};
}

test "util.ringbuffer" {
	var buffer = RingBuffer( u32, 4 ) {};

	try std.testing.expectEqual( true, buffer.push( 1 ) );
	try std.testing.expectEqual( true, buffer.push( 2 ) );
	try std.testing.expectEqual( true, buffer.push( 3 ) );
	try std.testing.expectEqual( true, buffer.push( 4 ) );
	try std.testing.expectEqual( false, buffer.push( 5 ) );

	try std.testing.expectEqual( @as( ?u32, 1 ), buffer.pop() );
	try std.testing.expectEqual( @as( ?u32, 2 ), buffer.pop() );
	try std.testing.expect( buffer.peek().?.* == 3 );

	try std.testing.expectEqual( true, buffer.push( 6 ) );
	try std.testing.expectEqual( @as( ?u32, 3 ), buffer.pop() );
	try std.testing.expectEqual( @as( ?u32, 4 ), buffer.pop() );
	try std.testing.expectEqual( @as( ?u32, 6 ), buffer.pop() );
	try std.testing.expectEqual( @as( ?u32, null ), buffer.pop() );
	try std.testing.expectEqual( @as( ?*u32, null ), buffer.peek() );

	try std.testing.expectEqual( true, buffer.push( 7 ) );
	try std.testing.expectEqual( @as( ?u32, 7 ), buffer.pop() );
	try std.testing.expectEqual( @as( ?u32, null ), buffer.pop() );
}
