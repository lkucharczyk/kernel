const std = @import( "std" );
const mem = @import( "../mem.zig" );
const Header = @import( "./rsdt.zig" ).Header;

const PowerProfile = enum(u8) {
	Unspecified = 0,
	Desktop = 1,
	Mobile = 2,
	Workstation = 3,
	EnterpriseServer = 4,
	_
};

pub const Fadt = extern struct {
	pub const MAGIC: *const [4]u8 = "FACP";

	header: Header,
	facsPtr: u32,
	dsdtPtr: u32,
	_: u8,
	powerProfile: PowerProfile,
	sciIntPin: u16,
	smiPort: u32,

	pub fn format( self: Fadt, _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		try std.fmt.format( writer, "{s}{{ .header = {}, .facsPtr = FACS@{x:0>8}, .dsdtPtr = DSDT@{x:0>8}, .powerProfile = .{s}, .sciPinInt = {}, .smiPort = 0x{x} }}", .{
			@typeName( Fadt ),
			self.header,
			self.facsPtr + mem.ADDR_KMAIN_OFFSET,
			self.dsdtPtr + mem.ADDR_KMAIN_OFFSET,
			@tagName( self.powerProfile ),
			self.sciIntPin,
			self.smiPort
		} );
	}
};
