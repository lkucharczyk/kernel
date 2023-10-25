const ADDR_KMAIN_OFFSET = 0xc000_0000;
const KMAIN_PAGES = 1;
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
		hugePage: bool = false,
	};

	const Entry = packed struct(u32) {
		flags: Flags = .{},
		_: u4 = 0,
		address: u20 = 0
	};

	entries: [1024]Entry = .{ .{} } ** 1024,

	pub fn init( comptime pages: comptime_int ) PagingDir {
		@setRuntimeSafety( false );

		var out: PagingDir = .{};
		const flags: Flags = .{
			.present = true,
			.writeable = true,
			.hugePage = true
		};

		out.entries[0] = .{ .address = 0, .flags = flags };

		const kpage = ADDR_KMAIN_OFFSET >> 22;
		for ( kpage..( kpage + pages ), 0.. ) |i, j| {
			out.entries[i] = .{ .address = @truncate( j << 10 ), .flags = flags };
		}

		return out;
	}
};

pub export var pagingDir: PagingDir align(4096) linksection(".multiboot") = PagingDir.init( KMAIN_PAGES );

pub fn init() void {
	if ( @intFromPtr( &ADDR_KMAIN_END ) > ADDR_KMAIN_OFFSET + KMAIN_PAGES * 4 * 1024 * 1024 ) {
		@panic( "Not enough pages for static kernel memory" );
	}
}
