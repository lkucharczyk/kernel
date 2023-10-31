const std = @import( "std" );
const root = @import( "root" );

pub const Device = @import( "./net/device.zig" ).Device;
pub const Interface = @import( "./net/interface.zig" ).Interface;

var interfaces: std.ArrayList( Interface ) = undefined;

pub fn init() void {
	interfaces = std.ArrayList( Interface ).init( root.kheap );
}

pub fn createInterface( device: Device ) *Interface {
	var ptr = interfaces.addOne() catch unreachable;

	ptr.device = device;
	ptr.init( root.kheap );

	return ptr;
}
