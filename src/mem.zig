const std = @import( "std" );
const root = @import( "root" );

const KMAIN_PAGES = 2;
pub const ADDR_KMAIN_OFFSET = 0xc000_0000;
extern const ADDR_KMAIN_END: u8;

pub const PAGE_SIZE = 0x40_0000;
pub const PAGE_LOG2 = std.math.log2( PAGE_SIZE );

pub const PagingDir = extern struct {
	pub const Flags = packed struct(u8) {
		pub const KERNEL_HUGE_RO = Flags {
			.present = true,
			.hugePage = true
		};

		pub const KERNEL_HUGE_RW = Flags {
			.present = true,
			.writeable = true,
			.hugePage = true
		};

		pub const USER_HUGE_RW = Flags {
			.present = true,
			.user = true,
			.writeable = true,
			.hugePage = true
		};

		present: bool = false,
		writeable: bool = false,
		user: bool = false,
		writeThrough: bool = false,
		noCache: bool = false,
		/// readonly
		accessed: bool = false,
		/// readonly
		dirty: bool = false,
		hugePage: bool = true,
	};

	const Entry = packed struct(u32) {
		flags: Flags = .{},
		_: u4 = 0,
		// normal mode
		//address: u20 = 0
		// huge pages
		pat: bool = false,
		addressHigh: u8 = 0,
		_1: u1 = 0,
		addressLow: u10 = 0,
	};

	entries: [1024]Entry = .{ .{} } ** 1024,

	pub fn init( comptime pages: comptime_int ) PagingDir {
		@setRuntimeSafety( false );

		var out: PagingDir = .{};
		out.entries[0] = .{ .addressLow = 0, .flags = Flags.KERNEL_HUGE_RW };

		const kpage = ADDR_KMAIN_OFFSET >> 22;
		for ( kpage..( kpage + pages ), 0.. ) |i, j| {
			out.entries[i] = .{ .addressLow = j, .flags = Flags.KERNEL_HUGE_RW };
		}

		return out;
	}

	pub fn find( self: PagingDir, phys: u10 ) ?usize {
		for ( self.entries, 0.. ) |e, i| {
			if ( e.addressLow == phys and e.flags.present ) {
				return i;
			}
		}

		return null;
	}

	pub inline fn map( self: *PagingDir, virt: u10, phys: u10, flags: Flags ) void {
		self.entries[virt] = .{ .addressLow = phys, .flags = flags };
		root.arch.invalidateTlb();
	}

	pub inline fn unmap( self: *PagingDir, virt: u10 ) void {
		self.entries[virt].flags.present = false;
		root.arch.invalidateTlb();
	}
};

pub export var _pagingDir: PagingDir align(4096) linksection(".multiboot") = PagingDir.init( KMAIN_PAGES );
pub var pagingDir: *PagingDir align(4096) = undefined;
pub var physicalPages: std.bit_set.ArrayBitSet( usize, 1024 ) = undefined;

pub var kbrk: usize = ADDR_KMAIN_OFFSET + ( KMAIN_PAGES << PAGE_LOG2 );
var kpages: u10 = KMAIN_PAGES;
fn ksbrk( inc: usize ) usize {
	while ( kbrk + inc >= ADDR_KMAIN_OFFSET + @as( usize, kpages ) * PAGE_SIZE ) {
		const phys = allocPhysical( true ) catch return 0;
		const virt = ( ADDR_KMAIN_OFFSET >> PAGE_LOG2 ) + kpages;
		kpages += 1;

		// root.log.printUnsafe(
		// 	"ksbrk: alloc {}:0x{x}-0x{x}\n",
		// 	.{ phys, @as( usize, virt ) << PAGE_LOG2, @as( usize, virt + 1 ) << PAGE_LOG2 }
		// );
		pagingDir.map( virt, phys, PagingDir.Flags.KERNEL_HUGE_RW );
	}

	const out = kbrk;
	kbrk += inc;
	// root.log.printUnsafe( "ksbrk: 0x{x} + 0x{x} -> 0x{x}\n", .{ out, inc, kbrk } );
	return out;
}

pub var kheapSbrk = std.heap.SbrkAllocator( ksbrk ) {};
pub var kheapGpa = std.heap.GeneralPurposeAllocator( .{ .safety = false } ) {};

pub fn init() void {
	root.log.printUnsafe( "mem: {}/{} KB\n\n", .{
		( @intFromPtr( &ADDR_KMAIN_END ) - ADDR_KMAIN_OFFSET ) / 1024,
		KMAIN_PAGES * 4 * 1024
	} );

	if ( @intFromPtr( &ADDR_KMAIN_END ) > ADDR_KMAIN_OFFSET + KMAIN_PAGES * 4 * 1024 * 1024 ) {
		@panic( "Not enough pages for static kernel memory" );
	}

	pagingDir = @ptrFromInt( @intFromPtr( &_pagingDir ) + ADDR_KMAIN_OFFSET );
	physicalPages = std.bit_set.ArrayBitSet( usize, 1024 ).initEmpty();
	for ( 0..KMAIN_PAGES ) |p| {
		physicalPages.set( p );
	}
}

pub fn allocPhysical( zero: bool ) error{ OutOfMemory }!u10 {
	for ( 0..1024 ) |i| {
		if ( !physicalPages.isSet( i ) ) {
			// root.log.printUnsafe( "mem.alloc: {}\n", .{ i } );
			physicalPages.set( i );

			if ( zero ) {
				pagingDir.map( 1023, @truncate( i ), PagingDir.Flags.KERNEL_HUGE_RW );
				@memset( @as( [*]usize, @ptrFromInt( 1023 << PAGE_LOG2 ) )[0..( PAGE_SIZE / @sizeOf( usize ) )], 0 );
				pagingDir.unmap( 1023 );
			}

			return @truncate( i );
		}
	}

	return error.OutOfMemory;
}

pub fn dupePhysical( page: u10 ) error{ OutOfMemory }!u10 {
	const newPage = try allocPhysical( false );
	errdefer freePhysical( newPage );

	// root.log.printUnsafe( "mem.dupe: {} {}\n", .{ page, newPage } );

	const srcPage: ?usize = pagingDir.find( page );
	if ( srcPage == null ) {
		pagingDir.map( 1022, page, PagingDir.Flags.KERNEL_HUGE_RO );
	}

	pagingDir.map( 1023, newPage, PagingDir.Flags.KERNEL_HUGE_RW );

	const size = PAGE_SIZE >> std.math.log2( @sizeOf( usize ) );
	const dst = @as( [*]usize, @ptrFromInt( 1023 << 22 ) )[0..size];
	const src = @as( [*]const allowzero usize, @ptrFromInt( ( srcPage orelse 1022 ) << 22 ) )[0..size];

	@memcpy( dst, src );
	// std.debug.assert( std.mem.eql( usize, dst, src ) );

	if ( srcPage == null ) {
		pagingDir.unmap( 1022 );
	}

	pagingDir.unmap( 1023 );
	return newPage;
}

pub fn freePhysical( page: u10 ) void {
	// root.log.printUnsafe( "mem.free: {}\n", .{ page } );
	physicalPages.unset( page );
}
