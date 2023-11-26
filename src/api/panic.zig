const std = @import( "std" );
const system = @import( "./system.zig" );

fn osWrite( fd: i32, buf: []const u8 ) error{}!usize {
	return std.os.system.write( fd, buf.ptr, buf.len );
}

fn openDwarfInfo() !std.dwarf.DwarfInfo {
	const alloc = std.heap.page_allocator;

	const ELF_BUFSIZE = 512 * 1024;
	const fd: i32 = @bitCast( system.open( std.os.argv[0], std.os.linux.O.RDONLY, 0 ) );
	var elf = try alloc.alloc( u8, ELF_BUFSIZE );

	var s: usize = system.read( fd, elf.ptr, elf.len );
	while ( s == ELF_BUFSIZE ) : ( s = std.os.linux.read( fd, elf.ptr[( elf.len - ELF_BUFSIZE )..], ELF_BUFSIZE ) ) {
		if ( alloc.resize( elf, elf.len + ELF_BUFSIZE ) ) {
			elf.len += ELF_BUFSIZE;
		} else {
			elf = try alloc.realloc( elf, elf.len + ELF_BUFSIZE );
		}
	}

	elf.len -= ELF_BUFSIZE - s;
	_ = system.close( fd );

	var stream = std.io.fixedBufferStream( elf );
	var header = try std.elf.Header.read( &stream );
	var sections: std.dwarf.DwarfInfo.SectionArray = std.dwarf.DwarfInfo.null_section_array;

	const sectionNames: *std.elf.Elf32_Shdr = @alignCast( @ptrCast( elf[@truncate( header.shoff + header.shentsize * header.shstrndx )..] ) );
	var iter = header.section_header_iterator( stream );
	while ( iter.next() catch null ) |sh| {
		const name = std.mem.sliceTo( elf[( sectionNames.sh_offset + sh.sh_name )..], 0 );

		if (
			std.ComptimeStringMap( std.dwarf.DwarfSection, .{
				.{ ".debug_abbrev", .debug_abbrev },
				.{ ".debug_frame" , .debug_frame  },
				.{ ".debug_info"  , .debug_info   },
				.{ ".debug_line"  , .debug_line   },
				.{ ".debug_ranges", .debug_ranges },
				.{ ".debug_str"   , .debug_str    },
			} ).get( name )
		) |section| {
			sections[@intFromEnum( section )] = std.dwarf.DwarfInfo.Section {
				.data = elf[@truncate( sh.sh_offset )..@truncate( sh.sh_offset + sh.sh_size )],
				.owned = true,
				.virtual_address = @truncate( sh.sh_offset )
			};
		}
	}

	var info = std.dwarf.DwarfInfo {
		.endian = @import( "builtin" ).cpu.arch.endian(),
		.is_macho = false,
		.sections = sections
	};

	try std.dwarf.openDwarfDebugInfo( &info, alloc );
	return info;
}

pub fn printStack( writer: anytype ) anyerror!void {
	var si = std.debug.StackIterator.init( @returnAddress(), null );
	var info: ?std.dwarf.DwarfInfo = openDwarfInfo() catch |err| _: {
		std.fmt.format( writer, "! Unable to retrieve symbol information: {}\n", .{ err } ) catch {};
		break :_ null;
	};

	while ( si.next() ) |ra| {
		try std.fmt.format( writer, "[0x{x:0>8}] {s}\n", .{
			@as( u32, @truncate( ra ) ),
			if ( info ) |*i| ( i.getSymbolName( ra - 1 ) orelse "<unknown>" ) else ( "<unknown>" ),
		} );
	}
}

var inPanic: bool = false;
pub fn panic( msg: []const u8, trace: ?*std.builtin.StackTrace, retAddr: ?usize ) noreturn {
	_ = trace;
	_ = retAddr;

	const writer = std.io.Writer( i32, error{}, osWrite ) { .context = 2 };
	while ( inPanic ) {
		try std.fmt.format( writer, "\x1b[97m" ++ "\n!!! Double panic: {s}\n", .{ msg } );
		system.exit( 2 );
	}
	inPanic = true;

	try std.fmt.format( writer, "\x1b[97m" ++ "\n!!! Task panic: {s}\n\nStack trace:\n", .{ msg } );
	printStack( writer ) catch {};
	_ = try writer.write( "\x1b[0m" );

	while ( true ) {
		system.exit( 1 );
	}
}
