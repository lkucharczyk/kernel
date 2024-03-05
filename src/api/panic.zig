const std = @import( "std" );
const elf = @import( "../elf.zig" );
const system = @import( "./system.zig" );
const FileStream = @import( "./file.zig" ).FileStream;

fn osWrite( fd: i32, buf: []const u8 ) error{}!usize {
	return std.os.system.write( fd, buf.ptr, buf.len );
}

pub fn openDwarfInfo( path: [*:0]const u8, alloc: std.mem.Allocator ) !elf.DwarfInfo {
	var info = _: {
		const fd: i32 = @bitCast( system.open( path, .{ .ACCMODE = .RDONLY }, 0 ) );
		if ( fd < 0 ) {
			return @import( "../task.zig" ).Error.MissingFile;
		}

		defer _ = system.close( fd );

		var stream = FileStream { .fd = fd };

		const curElf = try elf.read( stream.reader(), stream.seekableStream() );
		break :_ try curElf.readDwarfInfo( alloc );
	};

	try std.dwarf.openDwarfDebugInfo( &info.info, alloc );
	return info;
}

pub fn printStack( writer: anytype ) anyerror!void {
	var si = std.debug.StackIterator.init( @returnAddress(), null );

	var arena = std.heap.ArenaAllocator.init( std.heap.page_allocator );
	const alloc = arena.allocator();
	defer arena.deinit();

	var info: ?elf.DwarfInfo = if ( std.os.argv.len >= 1 ) (
		openDwarfInfo( std.os.argv[0], alloc ) catch |err| _: {
			std.fmt.format( writer, "! Unable to retrieve symbol information: {}\n", .{ err } ) catch {};
			break :_ null;
		}
	) else (
		null
	);

	while ( si.next() ) |ra| {
		if ( ra == 0 ) {
			break;
		}

		try std.fmt.format( writer, "[0x{x:0>8}] ", .{ @as( u32, @truncate( ra ) ) } );
		if ( ra > @import( "../mem.zig" ).ADDR_KMAIN_OFFSET ) {
			_ = try writer.write( "<kernel:unknown>\n" );
			continue;
		} else if ( info ) |*i| {
			if ( i.printSymbol( writer, alloc, ra ) catch false ) {
				continue;
			}
		}

		_ = try writer.write( "<unknown>\n" );
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
