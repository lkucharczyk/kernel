const std = @import( "std" );

pub const ADDR_KMAIN_OFFSET = 0xc000_0000;
const KMAIN_PAGES = 1;
const KHEAP_PAGES = 1;
extern const ADDR_KMAIN_END: u8;

pub const PagingDir = extern struct {
	const Flags = packed struct(u8) {
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
		const flags: Flags = .{
			.user = true,
			.present = true,
			.writeable = true,
			.hugePage = true
		};

		out.entries[0] = .{ .addressLow = 0, .flags = flags };

		const kpage = ADDR_KMAIN_OFFSET >> 22;
		for ( kpage..( kpage + pages ), 0.. ) |i, j| {
			out.entries[i] = .{ .addressLow = j, .flags = flags };
		}

		const acpiOffset = 0x07fe_0000 >> 22;
		out.entries[kpage + acpiOffset] = .{
			.addressLow = acpiOffset,
			.flags = .{ .present = true, .hugePage = true }
		};

		return out;
	}
};

pub export var _pagingDir: PagingDir align(4096) linksection(".multiboot") = PagingDir.init( KMAIN_PAGES + KHEAP_PAGES );
pub var pagingDir: *PagingDir align(4096) = undefined;
pub var physicalPages: std.bit_set.ArrayBitSet( usize, 1024 ) = undefined;

pub var kheapFba = std.heap.FixedBufferAllocator.init(
	@as( [*]u8, @ptrFromInt( ADDR_KMAIN_OFFSET + KMAIN_PAGES * 0x40_0000 ) )[0..( KHEAP_PAGES * 0x40_0000 )]
);
pub var kheapGpa = std.heap.GeneralPurposeAllocator( .{
	.enable_memory_limit = true,
	.safety = false
} ) {};

pub fn init() void {
	@import( "root" ).log.printUnsafe( "mem: {}/{} KB\n\n", .{
		( @intFromPtr( &ADDR_KMAIN_END ) - ADDR_KMAIN_OFFSET ) / 1024,
		KMAIN_PAGES * 4 * 1024
	} );

	if ( @intFromPtr( &ADDR_KMAIN_END ) > ADDR_KMAIN_OFFSET + KMAIN_PAGES * 4 * 1024 * 1024 ) {
		@panic( "Not enough pages for static kernel memory" );
	}

	kheapGpa.setRequestedMemoryLimit( KHEAP_PAGES * 0x40_0000 );

	physicalPages = std.bit_set.ArrayBitSet( usize, 1024 ).initEmpty();
	for ( 0..( KMAIN_PAGES + KHEAP_PAGES + 1 ) ) |p| {
		physicalPages.set( p );
	}
	physicalPages.set( 0x07fe_0000 >> 22 );

	pagingDir = @ptrFromInt( @intFromPtr( &_pagingDir ) + ADDR_KMAIN_OFFSET );
}

pub fn allocPhysical() error{ OutOfMemory }!u10 {
	for ( 0..1024 ) |i| {
		if ( !physicalPages.isSet( i ) ) {
			// @import( "root" ).log.printUnsafe( "mem.alloc: {}\n", .{ i } );
			physicalPages.set( i );
			return @truncate( i );
		}
	}

	return error.OutOfMemory;
}

pub fn freePhysical( page: u10 ) void {
	// @import( "root" ).log.printUnsafe( "mem.free: {}\n", .{ page } );
	physicalPages.unset( page );
}
