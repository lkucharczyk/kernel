const std = @import( "std" );

const LazyPackage = struct {
	build: *const fn( *std.Build, std.Target, *Self ) anyerror!void,
	step: ?*std.Build.Step = null,

	pub fn getStep( self: *const LazyPackage, parent: *Self ) *std.Build.Step {
		if ( self.step == null ) {
			self.build( parent.step.owner, parent.target, parent ) catch unreachable;
		}

		return self.step.?;
	}
};

const Self = @This();

step: std.Build.Step,
packages: std.StringHashMap( LazyPackage ),
target: std.Target,

pub fn create( b: *std.Build, target: std.Target ) *Self {
	const self = b.allocator.create( Self ) catch @panic( "OOM" );
	self.* = .{
		.step = std.Build.Step.init( .{
			.id = .custom,
			.name = "packages",
			.owner = b
		} ),
		.packages = std.StringHashMap( LazyPackage ).init( b.allocator ),
		.target = target
	};

	return self;
}

pub fn getStep( self: *Self, name: []const u8 ) ?*std.Build.Step {
	if ( self.packages.getPtr( name ) ) |pkg| {
		return pkg.getStep( self );
	}

	return null;
}

pub fn registerPackage( self: *Self, name: []const u8, build: *const fn( *std.Build, std.Target, *Self ) anyerror!void ) void {
	self.packages.putNoClobber( name, .{ .build = build } ) catch @panic( "OOM" );
}

pub fn registerStep( self: *Self, name: []const u8, step: *std.Build.Step ) void {
	if ( self.packages.getPtr( name ) ) |pkg| {
		pkg.step = step;
	} else {
		self.packages.putNoClobber( name, .{ .build = undefined, .step = step } ) catch @panic( "OOM" );
	}
}

pub fn select( self: *Self, packages: []const u8 ) void {
	var packagesIter = std.mem.tokenizeAny( u8, packages, ", " );
	while ( packagesIter.next() ) |p| {
		if ( self.getStep( p ) ) |s| {
			self.step.dependOn( s );
		} else if ( p.len > 0 ) {
			std.debug.panic( "Missing package: {s}", .{ p } );
		}
	}
}
