const std = @import( "std" );
const root = @import( "root" );
const mem = @import( "../mem.zig" );
const Rsdt = @import( "./rsdt.zig" ).Rsdt;

const ADDR_RSDPSEARCH_START = mem.ADDR_KMAIN_OFFSET + 0x000e_0000;
const ADDR_RSDPSEARCH_END   = mem.ADDR_KMAIN_OFFSET + 0x0010_0000;

const Rsdp = extern struct {
	const MAGIC = [8]u8 { 'R', 'S', 'D', ' ', 'P', 'T', 'R', ' ' };

	magic: [8]u8 align(1) = MAGIC,
	checksum: u8 align(1),
	oemId: [6]u8 align(1),
	revision: u8 align(1),
	rsdtAddr: u32 align(1),

	pub fn getRsdt( self: Rsdp ) *const align(1) Rsdt {
		return @ptrFromInt( mem.ADDR_KMAIN_OFFSET + self.rsdtAddr );
	}

	pub fn validate( self: Rsdp ) bool {
		var sum: u8 = 0;
		for ( @as( [*]const u8, @ptrCast( &self ) )[0..@sizeOf( Rsdp )] ) |b| {
			sum +%= b;
		}

		return sum == 0;
	}

	pub fn format( self: Rsdp, _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		try std.fmt.format( writer, "{s}{{ .oemId = \"{s}\", .revision = {}, .rdstAddr = {} }}", .{
			@typeName( Rsdp ),
			self.oemId,
			self.revision,
			self.rsdtAddr
		} );
	}
};

pub var ptr: ?*Rsdp = null;

pub fn init() ?*Rsdp {
	for ( ADDR_RSDPSEARCH_START..ADDR_RSDPSEARCH_END ) |address| {
		var rawPtr: [*]u8 = @ptrFromInt( address );
		if ( std.mem.eql( u8, rawPtr[0..8], &Rsdp.MAGIC ) ) {
			ptr = @as( *Rsdp, @ptrCast( rawPtr ) );
			break;
		}

		rawPtr += 1;
	}

	return ptr;
}
