const std = @import( "std" );
const util = @import( "../tools/buildUtil.zig" );
const SymlinkStep = @import( "../tools/symlinkStep.zig" );
const PackagesStep = @import( "../tools/packagesStep.zig" );

pub fn register( packages: *PackagesStep ) void {
	packages.registerPackage( "musl", build );
}

pub fn build( b: *std.Build, target: std.Target, packages: *PackagesStep ) anyerror!void {
	var libcBuild = b.addSystemCommand( &.{
		"sh", "-c",
		"LIBCC=$(find $(clang -print-resource-dir)/lib -name 'libclang_rt.builtins*.a' -path '*i386*') ./configure"
			++ " --target=i386-freestanding-none"
			++ " --prefix=$1"
			++ " --syslibdir=$1/lib"
			++ " --enable-debug"
			++ " && make clean"
			++ " && rm -f a.out"
			++ " && make -sj install",
		"zig-build",
	} );

	const libcInstall = b.addInstallDirectory( .{
		.source_dir = libcBuild.addOutputFileArg( "musl" ),
		.install_dir = .prefix,
		.install_subdir = ""
	} );

	libcBuild.setCwd( .{ .path = "vendor/musl/" } );
	libcBuild.extra_file_dependencies = try util.findByExt( b.allocator, "vendor/musl/", ".c", false );
	util.setCcEnv( libcBuild, target.cpu.arch, null, "../..", .{
		.CFLAGS = "-DSYSCALL_NO_TLS=1"
	} );

	var libc = SymlinkStep.create( b, &.{
		.{ "./zig-out/bin/ldd", "../lib/libc.so" },
		.{ "./zig-out/lib/ld-musl-i386.so.1", "libc.so" },
		.{ "./zig-out/lib/ld-musl-x86.so.1", "libc.so" },
	} );
	libc.step.name = "install musl";
	libc.step.dependOn( &libcInstall.step );

	packages.registerStep( "musl", &libc.step );
}
