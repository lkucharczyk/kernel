const std = @import( "std" );
const mem = @import( "../mem.zig" );

const Header = extern struct {
	const MAGIC = [4]u8 { 'R', 'S', 'D', 'T' };

	magic: [4]u8 = MAGIC,
	len: u32,
	revision: u8,
	checksum: u8,
	oemId: [6]u8,
	oemTableId: [8]u8,
	oemRevision: u32,
	creatorId: u32,
	creatorRevision: u32,

	pub fn format( self: Header, _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		_ = try writer.write( @typeName( Header ) );
		try std.fmt.format( writer, "{{ .magic = \"{[magic]s}\", .len = {[len]}, .revision = {[revision]}, .checksum = {[checksum]}, .oemId = \"{[oemId]s}\", .oemTableId = \"{[oemTableId]s}\", .oemRevision = {[oemRevision]}, .creatorId = {[creatorId]}, .creatorRevision = {[creatorRevision]} }}", self );
	}
};

pub const Rsdt = opaque {
	pub fn validate( self: *const Rsdt ) bool {
		const header = self.getHeader();
		var sum: u8 = 0;
		for ( @as( [*]const u8, @ptrCast( &self ) )[@sizeOf( Header )..header.len] ) |b| {
			sum +%= b;
		}

		return sum == 0 and std.mem.eql( u8, &header.magic, &Header.MAGIC );
	}

	pub inline fn getHeader( self: *const Rsdt ) *const align(1) Header {
		return @ptrCast( self );
	}

	pub inline fn getTable( self: *const Rsdt, offset: usize ) ?*const align(1) Header {
		if ( offset < self.getTableCount() ) {
			return @ptrFromInt(
				@as( [*]align(1) u32, @ptrFromInt( @intFromPtr( self ) + @sizeOf( Header ) ) )[offset]
					+ mem.ADDR_KMAIN_OFFSET
			);
		}

		return null;
	}

	pub inline fn getTableCount( self: *const align(1) Rsdt ) usize {
		return ( self.getHeader().len - @sizeOf( Header ) ) / 4;
	}

	pub fn format( self: *const Rsdt, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		const header = self.getHeader();
		try std.fmt.format( writer, "{s}{{ .header = {}, .tables = [ ", .{ @typeName( Rsdt ), header } );

		var i: usize = 0;
		while ( self.getTable( i ) ) |theader| : ( i += 1 ) {
			if ( i != 0 ) {
				_ = try writer.write( ", " );
			}

			try std.fmt.format( writer, "{s}@{x:0>8}", .{ theader.magic, @intFromPtr( theader ) } );
		}

		_ = try writer.write( " ] }}" );
	}
};
