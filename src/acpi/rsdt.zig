const std = @import( "std" );
const mem = @import( "../mem.zig" );

pub const Header = extern struct {
	magic: [4]u8,
	len: u32,
	revision: u8,
	checksum: u8,
	oemId: [6]u8,
	oemTableId: [8]u8,
	oemRevision: u32,
	creatorId: [4]u8,
	creatorRevision: u32,

	pub fn validate( self: *const align(1) Header, magic: *const [4]u8 ) bool {
		var sum: u8 = 0;
		for ( @as( [*]const u8, @ptrCast( self ) )[0..self.len] ) |b| {
			sum +%= b;
		}

		return sum == 0 and std.mem.eql( u8, &self.magic, magic );
	}

	pub fn format( self: Header, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		_ = try writer.write( @typeName( Header ) );
		if ( fmt.len == 1 and fmt[0] == 'f' ) {
			try std.fmt.format( writer, "{{ .magic = \"{[magic]s}\", .len = {[len]}, .revision = {[revision]}, .checksum = {[checksum]}, .oemId = \"{[oemId]s}\", .oemTableId = \"{[oemTableId]s}\", .oemRevision = {[oemRevision]}, .creatorId = \"{[creatorId]s}\", .creatorRevision = {[creatorRevision]} }}", self );
		} else {
			try std.fmt.format( writer, "{{ .magic = \"{s}\", .len = {}, ... }}", .{ self.magic, self.len } );
		}
	}
};

pub const Rsdt = opaque {
	const MAGIC: *const [4]u8 = "RSDT";

	pub inline fn validate( self: *const Rsdt ) bool {
		return self.getHeader().validate( MAGIC );
	}

	pub inline fn getHeader( self: *const Rsdt ) *const align(1) Header {
		return @ptrCast( self );
	}

	pub inline fn getTable( self: *const Rsdt, comptime T: type ) ?*const align(1) T {
		if ( !@hasDecl( T, "MAGIC" ) ) {
			@compileError( "Invalid ACPI SDT type" );
		}

		for ( 0..self.getTableCount() ) |i| {
			if ( self.getTableHeader( i ) ) |header| {
				if ( header.validate( T.MAGIC ) ) {
					return @ptrCast( header );
				}
			}
		}

		return null;
	}

	pub inline fn getTableHeader( self: *const Rsdt, offset: usize ) ?*const align(1) Header {
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
		try std.fmt.format( writer, "{s}{{ .header = {f}, .tables = [ ", .{ @typeName( Rsdt ), header } );

		var i: usize = 0;
		while ( self.getTableHeader( i ) ) |theader| : ( i += 1 ) {
			if ( i != 0 ) {
				_ = try writer.write( ", " );
			}

			try std.fmt.format( writer, "{s}@{x:0>8}", .{ theader.magic, @intFromPtr( theader ) } );
		}

		_ = try writer.write( " ] }}" );
	}
};
