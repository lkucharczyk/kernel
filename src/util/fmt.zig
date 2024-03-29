const std = @import( "std" );

pub fn BitFlags( comptime T: type ) type {
	const zeroDecl: ?[]const u8 = comptime _: {
		for ( @typeInfo( T ).Struct.decls ) |d| {
			const val = @field( T, d.name );

			if ( val == 0 ) {
				break :_ d.name;
			}
		}

		break :_ null;
	};

	return struct {
		data: usize,
		pub fn format( self: @This(), _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
			var first = true;
			inline for ( @typeInfo( T ).Struct.decls ) |d| {
				const val = @field( T, d.name );

				if ( val > 0 and ( self.data & val ) == val ) {
					if ( first ) {
						_ = try writer.write( d.name );
						first = false;
					} else {
						_ = try writer.write( " | " ++ d.name );
					}
				}
			}

			if ( first and zeroDecl != null ) {
				_ = try writer.write( zeroDecl.? );
			}
		}
	};
}

pub fn BitFlagsStruct( comptime T: type ) type {
	return struct {
		data: T,
		pub fn format( self: @This(), _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
			const name = comptime _: {
				const name = @typeName( T );
				break :_ name[0..( std.mem.indexOf( u8, name, "__struct_" ) orelse name.len )];
			};
			_ = try writer.write( name ++ "{ " );

			comptime var firstField = true;
			inline for ( @typeInfo( T ).Struct.fields ) |f| {
				if ( f.type != bool and f.name[0] != '_' ) {
					if ( !firstField ) {
						try std.fmt.format( writer, ", .{s} = {}", .{ f.name, @field( self.data, f.name ) } );
					} else {
						try std.fmt.format( writer, ".{s} = {}", .{ f.name, @field( self.data, f.name ) } );
					}
					firstField = false;
				}
			}

			var firstFlag = true;
			inline for ( @typeInfo( T ).Struct.fields ) |f| {
				if ( f.type == bool and @field( self.data, f.name ) ) {
					if ( !firstFlag ) {
						_ = try writer.write( " | " ++ f.name );
					} else if ( !firstField ) {
						_ = try writer.write( ", " ++ f.name );
						firstFlag = false;
					} else {
						_ = try writer.write( f.name );
						firstFlag = false;
					}
				}
			}

			_ = try writer.write( " }" );
		}
	};
}

pub fn OptionalVal( comptime T: type, comptime fmt: []const u8 ) type {
	return struct {
		data: ?T,
		pub fn format( self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
			if ( self.data ) |data| {
				try std.fmt.format( writer, fmt, .{ data } );
			} else {
				_ = try writer.write( "null" );
			}
		}
	};
}

pub const OptionalCStr = OptionalVal( [*:0]const u8, "\"{s}\"" );
pub const OptionalStr = OptionalVal( []const u8, "\"{s}\"" );
