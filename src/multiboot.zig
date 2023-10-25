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

	flags: u32,
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
	fb_2: u16
};
