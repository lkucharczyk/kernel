const std = @import( "std" );
const root = @import( "root" );
const mem = @import( "../mem.zig" );

pub const Entry = packed struct {
	phys: u10,
	virt: u10,

	pub fn sort( _: void, e1: Entry, e2: Entry ) bool {
		return e1.virt < e2.virt;
	}

	pub fn format( self: Entry, _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) !void {
		try std.fmt.format( writer, "{}:{}", .{ self.virt, self.phys } );
	}
};

pub const MMap = struct {
	entries: std.ArrayList( Entry ),

	pub fn init( allocator: std.mem.Allocator ) MMap {
		return .{
			.entries = std.ArrayList( Entry ).init( allocator )
		};
	}

	pub fn initCapacity( allocator: std.mem.Allocator, n: usize ) std.mem.Allocator.Error!MMap {
		return .{
			.entries = try std.ArrayList( Entry ).initCapacity( allocator, n )
		};
	}

	pub fn deinit( self: MMap ) void {
		for ( self.entries.items ) |e| {
			mem.freePhysical( e.phys );
		}

		self.entries.deinit();
	}

	pub fn dupe( self: MMap, allocator: std.mem.Allocator ) std.mem.Allocator.Error!MMap {
		if ( self.entries.items.len == 0 ) {
			return MMap.init( allocator );
		}

		var out = try MMap.initCapacity( allocator, self.entries.items.len );
		errdefer out.deinit();

		for ( self.entries.items ) |e| {
			out.entries.appendAssumeCapacity( .{
				.phys = try mem.dupePhysical( e.phys ),
				.virt = e.virt
			} );
		}

		return out;
	}

	pub fn map( self: MMap ) void {
		for ( self.entries.items ) |e| {
			mem.pagingDir.map( e.virt, e.phys, mem.PagingDir.Flags.USER_HUGE_RW );
		}
	}

	pub fn unmap( self: MMap ) void {
		for ( self.entries.items ) |e| {
			mem.pagingDir.unmap( e.virt );
		}
	}

	pub fn containsAddr( self: MMap, addr: usize ) bool {
		const virt: u10 = @truncate( addr >> 22 );

		for ( self.entries.items ) |e| {
			if ( e.virt == virt ) {
				return true;
			}
		}

		return false;
	}

	pub fn containsSlice( self: MMap, addr: usize, size: usize ) bool {
		const virtStart: u10 = @truncate( addr >> 22 );
		const virtEnd: u10 = @truncate( ( addr + size - 1 ) >> 22 );
		var i: i10 = 0;

		for ( self.entries.items ) |e| {
			if ( e.virt >= virtStart and e.virt <= virtEnd ) {
				i += 1;
			}
		}

		return i == ( virtEnd - virtStart + 1 );
	}

	pub fn alloc( self: *MMap, addr: usize, size: usize ) std.mem.Allocator.Error!bool {
		const virtStart: u10 = @truncate( addr >> 22 );
		const virtEnd: u10 = @as( u10, @truncate( ( addr + size - 1 ) >> 22 ) ) + 1;
		var out: bool = false;

		for ( virtStart..virtEnd ) |virt| {
			if ( !self.containsAddr( virt << 22 ) ) {
				try self.entries.append( .{
					.phys = try mem.allocPhysical( false ),
					.virt = @truncate( virt )
				} );
				out = true;
			}
		}

		self.sort();
		return out;
	}

	pub fn free( self: *MMap, addr: usize, size: usize ) bool {
		const virtStart: u10 = @truncate( std.mem.alignForwardLog2( addr, 22 ) >> 22 );
		const virtEnd: u10 = @as( u10, @truncate( ( addr + size ) >> 22 ) );
		var out: bool = false;

		for ( virtStart..virtEnd ) |virt| {
			if ( !self.containsAddr( virt << 22 ) ) {
				for ( self.entries.items, 0.. ) |e, i| {
					if ( e.virt >= virtStart and e.virt <= virtEnd ) {
						_ = self.entries.orderedRemove( i );
						mem.freePhysical( e.phys );
						out = true;
					}
				}
			}
		}

		return out;
	}

	pub fn sort( self: *MMap ) void {
		std.sort.block( Entry, self.entries.items, {}, Entry.sort );
	}
};
