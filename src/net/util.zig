const isLe = @import( "builtin" ).cpu.arch.endian() == .Little;

pub fn Body( comptime N: comptime_int ) type {
	return struct {
		pub const PARTS = N;

		parts: [PARTS]?[]const u8,

		pub inline fn init( str: []const u8 ) @This() {
			return .{
				.parts = .{ str } ++ ( .{ null } ** ( PARTS - 1 ) )
			};
		}

		pub fn len( self: @This() ) usize {
			var out: usize = 0;
			for ( self.parts ) |mpart| {
				if ( mpart ) |part| {
					out += part.len;
				}
			}
			return out;
		}

		pub fn copyTo( self: @This(), dest: []u8 ) void {
			var pos: usize = 0;
			for ( self.parts ) |mpart| {
				if ( mpart ) |part| {
					@memcpy( dest[pos..( pos + part.len )], part );
					pos += part.len;
				}
			}
		}
	};
}

pub const NetBody = Body( 2 );
pub const HwBody = Body( 3 );

pub fn checksum( ptr: []const u16 ) u16 {
	var out: u16 = 0;
	for ( ptr ) |b| {
		const r = @addWithOverflow( out, b );
		out = r[0] + r[1];
	}

	return ~out;
}

pub fn checksumBody( start: u16, ptr: []const u8 ) u16 {
	var out: u16 = start;
	for ( 0..ptr.len ) |i| {
		var b: u16 = @intCast( ptr[i] );
		if ( ( i & 1 ) > 0 ) {
			b <<= 8;
		}

		const r = @addWithOverflow( out,  b );
		out = r[0] + r[1];
	}

	return ~out;
}

pub inline fn hton( comptime T: type, val: T ) T {
	if ( isLe ) {
		return switch ( @typeInfo( T )) {
			.Struct => |s| (
				if ( s.backing_integer ) |B| (
					@bitCast( @byteSwap( @as( B, @bitCast( val ) ) ) )
				) else (
					@compileError( "Invalid type" )
				)
			),
			.Enum => @enumFromInt( @byteSwap( @intFromEnum( val ) ) ),
			else => @byteSwap( val )
		};
	} else {
		return val;
	}
}