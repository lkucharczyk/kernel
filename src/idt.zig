const std = @import( "std" );
const x86 = @import( "./x86.zig" );

pub const Entry = extern struct {
	const Attributes = packed struct(u8) {
		gateType: u5 = 0b01110,
		ring: u2 = 0,
		present: bool = false
	};

	baseLow: u16 align(1) = 0,
	/// GDT entry
	selection: u16 align(1) = 0,
	_: u8 align(1) = 0,
	attrs: Attributes align(1) = .{},
	baseHigh: u16 align(1) = 0,

	pub fn set( self: *Entry, base: u32, selection: u16 ) void {
		self.baseLow = @truncate( base );
		self.baseHigh = @truncate( base >> 16 );
		self.selection = selection;
		self.attrs = .{ .present = true };
	}

	pub fn unset( self: *Entry ) void {
		self.attrs.present = false;
	}
};

pub var table: [256]Entry = std.mem.zeroes( [256]Entry );
var ptr: x86.TablePtr = undefined;

pub fn init() void {
	ptr = x86.TablePtr.init( Entry, 256, &table );
	asm volatile ( "lidt (%%eax)" :: [ptr] "{eax}" ( &ptr ) );
}
