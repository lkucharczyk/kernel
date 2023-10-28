const std = @import( "std" );
const root = @import( "root" );
const x86 = @import( "./x86.zig" );

const Address = packed struct(u16) {
	bus: u8,
	slot: u5,
	func: u3,

	fn register( self: Address, offset: u8 ) u32 {
		return 0x8000_0000
			| ( @as( u32, @intCast( self.bus ) ) << 16 )
			| ( @as( u32, @intCast( self.slot ) ) << 11 )
			| ( @as( u32, @intCast( self.func ) ) << 8 )
			| @as( u32, @intCast( offset ) );
	}

	pub fn format( self: Address, _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		try std.fmt.format( writer, "{x:0>2}:{x:0>2}.{}", .{ self.bus, self.slot, self.func } );
	}
};

const DeviceId = packed struct(u32) {
	vendorId: u16,
	deviceId: u16,

	pub fn format( self: DeviceId, _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		try std.fmt.format( writer, "{x:0>4}:{x:0>4}", .{ self.vendorId, self.deviceId } );
	}
};

const Command = packed struct(u16) {
	ioSpace: bool,
	memorySpace: bool,
	busMaster: bool,
	specialCycles: bool,
	memWrite: bool,
	vgaSnoop: bool,
	parityError: bool,
	_0: bool = false,
	serr: bool,
	fastB2B: bool,
	intDisable: bool,
	_1: u5 = 0
};

const Class = enum(u8) {
	Unclassified = 0,
	MassStorage = 1,
	Network = 2,
	Display = 3,
	Multimedia = 4,
	Memory = 5,
	Bridge = 6,
	SimpleComms = 7,
	BaseSystemPeripheral = 8,
	InputDevice = 9,
	DockingStation = 0x0a,
	Processor = 0x0b,
	SerialBus = 0x0c,
	Wireless = 0x0d,
	Intelligent = 0x0e,
	SatelliteComms = 0x0f,
	Encryption = 0x10,
	SignalProcessing = 0x11,
	_
};

const DeviceHeader = packed struct {
	deviceId: DeviceId,
	command: Command,
	status: u16,
	revisionId: u8,
	progIf: u8,
	subclass: u8,
	classCode: Class,
	cacheLineSize: u8,
	latencyTimer: u8,
	headerType: u7,
	multiFunction: bool,
	bist: u8
};

const DeviceHeaderExt0 = packed struct {
	barAddr0: u32,
	barAddr1: u32,
	barAddr2: u32,
	barAddr3: u32,
	barAddr4: u32,
	barAddr5: u32,
	cardbusCisPtr: u32,
	subsystem: DeviceId,
	expansionRomAddr: u32,
	capabilitiesPtr: u8,
	_: u56,
	intLine: u8,
	intPin: u8,
	minGrant: u8,
	maxLatency: u8
};

const DeviceHeaderExt1 = packed struct {
	barAddr0: u32,
	barAddr1: u32,
	busPrimary: u8,
	busSecondary: u8,
	busSubordinate: u8,
	secondaryLatencyTimer: u8,
	ioBase: u8,
	ioLimit: u8,
	secondaryStatus: u16,
	memoryBase: u16,
	memoryLimit: u16,
	prefetchableMemBase: u16,
	prefetchableMemLimit: u16,
	prefetchableMemBaseHigh: u32,
	prefetchableMemLimitHigh: u32,
	ioBaseHigh: u16,
	ioLimitHigh: u16,
	capabilitiesPtr: u8,
	_: u24,
	expansionRomAddr: u32,
	intLine: u8,
	intPin: u8,
	bridgeControl: u16
};

const DeviceHeaderExt = union(enum) {
	ext0: DeviceHeaderExt0,
	ext1: DeviceHeaderExt1,
	none
};

pub const Device = struct {
	address: Address,
	header: DeviceHeader,
	headerExt: DeviceHeaderExt,

	pub fn init( address: Address ) ?Device {
		var dev = Device {
			.address = address,
			.header = undefined,
			.headerExt = .none
		};

		const devId = dev.in( DeviceId, 0 );
		if ( devId.vendorId != 0xffff and devId.vendorId != 0 ) {
			dev.header = @bitCast( [4]u32 {
				@as( u32, @bitCast( devId ) ),
				dev.in( u32, 4 ),
				dev.in( u32, 8 ),
				dev.in( u32, 12 ),
			} );

			if ( dev.header.headerType == 0 ) {
				var buf: [12]u32 = .{ 0 } ** 12;
				inline for ( 0..buf.len ) |i| {
					buf[i] = dev.in( u32, ( i + 4 ) * 4 );
				}

				dev.headerExt = .{ .ext0 = @bitCast( buf ) };
			} else if ( dev.header.headerType == 1 ) {
				var buf: [12]u32 = .{ 0 } ** 12;
				inline for ( 0..buf.len ) |i| {
					buf[i] = dev.in( u32, ( i + 4 ) * 4 );
				}

				dev.headerExt = .{ .ext1 = @bitCast( buf ) };
			}

			return dev;
		}

		return null;
	}

	pub inline fn in( self: Device, comptime T: type, offset: u8 ) T {
		x86.out( u32, 0xcf8, self.address.register( offset ) );
		return x86.in( T, 0xcfc );
	}

	pub inline fn out( self: Device, comptime T: type, offset: u8, data: T ) void {
		x86.out( u32, 0xcf8, self.address.register( offset ) );
		return x86.out( T, 0xcfc, data );
	}
};

pub var devices: std.ArrayList( Device ) = undefined;

pub fn init() std.mem.Allocator.Error!void {
	devices = try std.ArrayList( Device ).initCapacity( root.kheap, 8 );

	for ( 0..0b1111_1111 ) |bus| {
		for ( 0..0b11111 ) |slot| {
			for ( 0..8 ) |func| {
				const address = Address {
					.bus = @intCast( bus ),
					.slot = @intCast( slot ),
					.func = @intCast( func )
				};

				if ( Device.init( address ) ) |dev| {
					root.log.printUnsafe( "pci: {} {} {}", .{
						dev.address,
						dev.header.deviceId,
						dev.header.classCode,
					} );

					if ( dev.headerExt == .ext0 and dev.headerExt.ext0.intPin != 0 ) {
						root.log.printUnsafe( " (irq: {})", .{ 32 + dev.headerExt.ext0.intLine } );
					}

					root.log.printUnsafe( "\n", .{} );

					try devices.append( dev );

					if ( func == 0 and !dev.header.multiFunction ) {
						break;
					}
				}
			}
		}
	}
}
