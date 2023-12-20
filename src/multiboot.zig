const std = @import( "std" );
const mem = @import( "./mem.zig" );

pub const Header = extern struct {
	const MAGIC = 0x1bad_b002;

	const Flags = packed struct(i32) {
		pageAlign: bool = false,
		memInfo: bool = false,
		videoInfo: bool = false,
		_: u29 = 0
	};

	magic: i32 = MAGIC,
	flags: Flags,
	checksum: i32,

	pub fn init( flags: Flags ) Header {
		return .{
			.flags = flags,
			.checksum = -( MAGIC + @as( i32, @bitCast( flags ) ) )
		};
	}
};

pub const Info = extern struct {
	pub const MAGIC = 0x2bad_b002;

	const Flags = packed struct(u32) {
		biosMemory: bool,
		bootDevice: bool,
		cmdline: bool,
		modules: bool,
		symbolTable: bool,
		elfSectionHeaderTable: bool,
		memoryMap: bool,
		driveInfo: bool,
		configTable: bool,
		bootLoaderName: bool,
		apmTable: bool,
		vbeInfo: bool,
		frameBufferInfo: bool,
		_: u19 = 0
	};

	flags: Flags,
	memLower: u32,
	memUpper: u32,
	bootDevice: u32,
	cmdline: u32,
	modsCount: u32,
	modsAddr: u32,

	u: [4]u32,

	mmapLen: u32,
	mmapAddr: u32,
	drivesLen: u32,
	drivesAddr: u32,
	configTable: u32,
	bootLoaderName: u32,
	apmTable: u32,

	vbeControlInfo: u32,
	vbeModeInfo: u32,
	vbeMode: u16,
	vbeInterfaceSeg: u16,
	vbeInterfaceOff: u16,
	vbeInterfaceLen: u16,

	fbAddr: u64,
	fbPitch: u32,
	fbWidth: u32,
	fbHeight: u32,
	fbBpp: u8,
	fbType: u8,
	fb_1: u32,
	fb_2: u16,

	pub fn getBootloaderName( self: Info ) ?[*:0]const u8 {
		if ( self.flags.bootLoaderName ) {
			return @ptrFromInt( mem.ADDR_KMAIN_OFFSET + self.bootLoaderName );
		}

		return null;
	}

	pub fn getCmdline( self: Info ) ?[:0]const u8 {
		if ( self.flags.cmdline ) {
			return std.mem.sliceTo( @as( [*:0]const u8, @ptrFromInt( mem.ADDR_KMAIN_OFFSET + self.cmdline ) ), 0 );
		}

		return null;
	}

	pub fn getMemoryMap( self: Info ) ?[]const MemoryMapEntry {
		if ( self.flags.memoryMap ) {
			return @as(
				[*]const MemoryMapEntry,
				@ptrFromInt( mem.ADDR_KMAIN_OFFSET + self.mmapAddr )
			)[0..(self.mmapLen / @sizeOf( MemoryMapEntry ))];
		}

		return null;
	}

	pub fn getModules( self: Info ) ?[]const Module {
		if ( self.flags.modules ) {
			return @as(
				[*]const Module,
				@ptrFromInt( mem.ADDR_KMAIN_OFFSET + self.modsAddr )
			)[0..self.modsCount];
		}

		return null;
	}
};

pub const MemoryMapEntry = extern struct {
	const Type = enum(u32) {
		Available = 1,
		Reserved = 2,
		AcpiReclaimable = 3,
		AcpiNvs = 4,
		BadRam = 5
	};

	size: u32 align(1),
	addr: u64 align(1),
	len: u64 align(1),
	mtype: Type align(1),

	pub fn format( self: MemoryMapEntry, _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		try std.fmt.format( writer, "{x:0>8}-{x:0>8} {}", .{ self.addr, self.addr + self.len - 1, self.mtype } );
	}
};

pub const Module = extern struct {
	addrStart: u32 align(1),
	addrEnd: u32 align(1),
	cmdline: u32 align(1),
	pad: u32 align(1),

	pub fn getCmdline( self: Module ) ?[:0]const u8 {
		if ( self.cmdline != 0 ) {
			return std.mem.sliceTo( @as( [*:0]const u8, @ptrFromInt( mem.ADDR_KMAIN_OFFSET + self.cmdline ) ), 0 );
		}

		return null;
	}

	pub fn getData( self: Module ) []u8 {
		return @as( [*]u8, @ptrFromInt( mem.ADDR_KMAIN_OFFSET + self.addrStart ) )[0..( self.addrEnd - self.addrStart )];
	}

	pub fn format( self: Module, _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		try std.fmt.format(
			writer,
			"{x:0>8}-{x:0>8} \"{s}\"",
			.{ mem.ADDR_KMAIN_OFFSET + self.addrStart, mem.ADDR_KMAIN_OFFSET + self.addrEnd - 1, self.getCmdline().? }
		);
	}
};
