const std = @import( "std" );

const Self = @This();

step: std.Build.Step,
links: []const [2][]const u8,

pub fn create( b: *std.Build, links: []const [2][]const u8 ) *Self {
	const self = b.allocator.create( Self ) catch @panic( "OOM" );
	self.* = .{
		.step = std.Build.Step.init( .{
			.id = .custom,
			.name = "symlink",
			.owner = b,
			.makeFn = make,
		} ),
		.links = links
	};

	return self;
}

pub fn make( step: *std.Build.Step, _: *std.Progress.Node ) anyerror!void {
	const self = @fieldParentPtr( Self, "step", step );
	const cwd = std.fs.cwd();

	for ( self.links ) |link| {
		cwd.deleteFile( link[0] ) catch |err| switch ( err ) {
			error.FileNotFound => {},
			else => return err
		};
		try cwd.symLink( link[1], link[0], .{} );
	}
}
