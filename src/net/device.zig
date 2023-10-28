const ethernet = @import( "./ethernet.zig" );

pub const Device = struct {
	pub const VTable = struct {
		send: *const fn( ctx: *anyopaque, frame: ethernet.Frame ) void,
	};

	context: *anyopaque,
	vtable: VTable,

	hwAddr: ethernet.Address,

	pub inline fn send( self: Device, frame: ethernet.Frame ) void {
		self.vtable.send( self.context, frame );
	}
};
