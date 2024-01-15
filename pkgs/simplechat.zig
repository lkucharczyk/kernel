const std = @import( "std" );
const util = @import( "../tools/buildUtil.zig" );
const PackagesStep = @import( "../tools/packagesStep.zig" );

pub fn register( packages: *PackagesStep ) void {
	packages.registerPackage( "simplechat", build );
	packages.registerPackage( "simplechat-server", build );
}

pub fn build( b: *std.Build, target: std.Target, packages: *PackagesStep ) anyerror!void {
	const ctarget = b.resolveTargetQuery( .{
		.cpu_arch = target.cpu.arch,
		.cpu_model = .{ .explicit = target.cpu.model },
		.abi = .musl,
		.os_tag = .linux
	} );

	var client = b.addExecutable( .{
		.name = "simplechat",
		.root_source_file = null,
		.single_threaded = true,
		.linkage = .static,
		.target = ctarget
	} );
	client.step.dependOn( packages.getStep( "musl" ).? );
	client.addCSourceFile( .{ .file = .{ .path = "./pkgs/simplechat/client.c" } } );
	client.addSystemIncludePath( .{ .path = "./zig-out/include" } );
	client.addLibraryPath( .{ .path = "./zig-out/lib" } );
	client.linkLibC();

	var server = b.addExecutable( .{
		.name = "simplechat-server",
		.root_source_file = null,
		.single_threaded = true,
		.linkage = .static,
		.target = ctarget
	} );
	server.step.dependOn( packages.getStep( "musl" ).? );
	server.addCSourceFile( .{ .file = .{ .path = "./pkgs/simplechat/server.c" } } );
	server.addSystemIncludePath( .{ .path = "./zig-out/include" } );
	server.addLibraryPath( .{ .path = "./zig-out/lib" } );
	server.linkLibC();

	packages.registerStep( "simplechat", &b.addInstallBinFile( client.getEmittedBin(), "simplechat" ).step );
	packages.registerStep( "simplechat-server", &b.addInstallBinFile( server.getEmittedBin(), "simplechat-server" ).step );
}
