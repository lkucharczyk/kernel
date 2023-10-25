const std = @import( "std" );
const root = @import( "root" );

const Rsdp = extern struct {
	const MAGIC = [8]u8 { 'R', 'S', 'D', ' ', 'P', 'T', 'R', ' ' };

	magic: [8]u8 align(1) = MAGIC,
	checksum: u8 align(1),
	oemId: [6]u8 align(1),
	revision: u8 align(1),
	rsdtAddr: u32 align(1),

	pub fn validate( self: Rsdp ) bool {
		var sum: u8 = 0;

		for ( self.magic ) |b| {
			sum +%= b;
		}

		sum +%= self.checksum;

		for ( self.oemId ) |b| {
			sum +%= b;
		}

		sum +%= self.revision;
		sum +%= @truncate( self.rsdtAddr & 0xff );
		sum +%= @truncate( ( self.rsdtAddr >> 8 ) & 0xff );
		sum +%= @truncate( ( self.rsdtAddr >> 16 ) & 0xff );
		sum +%= @truncate( ( self.rsdtAddr >> 24 ) & 0xff );

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
	var rawPtr: [*]u8 = @ptrFromInt( 0xc00e_0000 );
	while ( @intFromPtr( rawPtr ) < 0xc010_0000 ) {
		if ( std.mem.eql( u8, rawPtr[0..8], &Rsdp.MAGIC ) ) {
			ptr = @as( *Rsdp, @ptrCast( rawPtr ) );
			break;
		}

		rawPtr += 1;
	}

	return ptr;
}
