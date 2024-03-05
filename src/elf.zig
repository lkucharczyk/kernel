const std = @import( "std" );
const AnySeekableStream = @import( "./util/stream.zig" ).AnySeekableStream;

const DwarfError = error{ MissingDebugInfo };
pub const DwarfInfo = struct {
	info: std.dwarf.DwarfInfo,

	pub inline fn getSymbolName( self: *DwarfInfo, addr: usize ) ?[]const u8 {
		return self.info.getSymbolName( addr );
	}

	pub inline fn getSymbolLineInfo( self: *DwarfInfo, alloc: std.mem.Allocator, addr: usize ) ?std.debug.LineInfo {
		const cu = self.info.findCompileUnit( addr ) catch return null;
		return self.info.getLineNumberInfo( alloc, cu.*, addr ) catch return null;
	}

	pub fn printSymbol( self: *DwarfInfo, writer: anytype, alloc: std.mem.Allocator, addr: usize ) anyerror!bool {
		if ( self.getSymbolName( addr ) ) |n| {
			if ( self.getSymbolLineInfo( alloc, addr ) ) |li| {
				defer li.deinit( alloc );

				const off = if ( std.mem.lastIndexOf( u8, li.file_name, "/src/" ) ) |o| ( o + 5 ) else ( 0 );
				try std.fmt.format( writer, "{s} ({s}:{}:{})\n", .{ n, li.file_name[off..], li.line, li.column } );
			} else {
				try std.fmt.format( writer, "{s}\n", .{ n } );
			}

			return true;
		}

		return false;
	}
};

const Elf32 = struct {
	header: std.elf.Elf32_Ehdr,
	reader: std.io.AnyReader,
	seeker: AnySeekableStream,

	pub fn readProgramTable( self: Elf32, alloc: std.mem.Allocator ) anyerror![]std.elf.Elf32_Phdr {
		try self.seeker.seekTo( self.header.e_phoff );
		const segments = try alloc.alloc( std.elf.Elf32_Phdr, self.header.e_phnum );

		_ = try self.reader.readAll( std.mem.sliceAsBytes( segments ) );

		return segments;
	}

	pub fn readSectionTable( self: Elf32, alloc: std.mem.Allocator ) anyerror![]std.elf.Elf32_Shdr {
		try self.seeker.seekTo( self.header.e_shoff );
		const sections = try alloc.alloc( std.elf.Elf32_Shdr, self.header.e_shnum );

		_ = try self.reader.readAll( std.mem.sliceAsBytes( sections ) );

		return sections;
	}

	pub fn readNameTable( self: Elf32, alloc: std.mem.Allocator ) anyerror![]u8 {
		try self.seeker.seekTo( self.header.e_shoff + self.header.e_shentsize * self.header.e_shstrndx );
		const sectionNamesHeader = try self.reader.readStruct( std.elf.Elf32_Shdr );
		try self.seeker.seekTo( sectionNamesHeader.sh_offset );

		const names = try alloc.alloc( u8, sectionNamesHeader.sh_size );
		_ = try self.reader.readAll( names );

		return names;
	}

	pub fn readDwarfInfo( self: Elf32, alloc: std.mem.Allocator ) anyerror!DwarfInfo {
		var info = std.dwarf.DwarfInfo {
			.endian = @import( "builtin" ).cpu.arch.endian(),
			.is_macho = false
		};

		const elfSections = try self.readSectionTable( alloc );
		defer alloc.free( elfSections );

		const names = try self.readNameTable( alloc );
		defer alloc.free( names );

		for ( elfSections ) |sh| {
			const name = std.mem.sliceTo( names[sh.sh_name..], 0 );

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
				if ( sh.sh_size == 0 ) {
					continue;
				}

				try self.seeker.seekTo( sh.sh_offset );
				const raw = try alloc.alloc( u8, @truncate( sh.sh_size ) );
				_ = try self.reader.readAll( raw );

				const data = if ( ( sh.sh_flags & std.elf.SHF_COMPRESSED ) > 0 ) _: {
					defer alloc.free( raw );

					var rawStream = std.io.fixedBufferStream( raw );
					const chdr = rawStream.reader().readStruct( std.elf.Elf32_Chdr ) catch continue;

					const decompressed = try alloc.alloc( u8, chdr.ch_size );
					errdefer alloc.free( decompressed );

					switch ( chdr.ch_type ) {
						.ZLIB => {
							var zlibStream = std.compress.zlib.decompressor( rawStream.reader() );
							_ = try zlibStream.reader().readAll( decompressed );
						},
						// .ZSTD => {
						// 	const buf = try alloc.alloc( u8, 1 << 23 );
						// 	defer alloc.free( buf );

						// 	var zstdStream = std.compress.zstd.decompressor( rawStream.reader(), .{
						// 		.window_buffer = buf
						// 	} );
						// 	_ = try zstdStream.reader().readAll( decompressed );
						// },
						else => continue
					}

					break :_ decompressed;
				} else (
					raw
				);

				info.sections[@intFromEnum( section )] = .{
					.data = data,
					.owned = true,
					.virtual_address = sh.sh_addr
				};
			}
		}

		if ( info.section( .debug_info ) == null ) {
			return DwarfError.MissingDebugInfo;
		}

		return .{ .info = info };
	}
};

pub fn read( reader: std.io.AnyReader, seeker: AnySeekableStream ) anyerror!Elf32 {
	return .{
		.header = try reader.readStruct( std.elf.Elf32_Ehdr ),
		.reader = reader,
		.seeker = seeker
	};
}
