const std = @import( "std" );
const qemu = @import( "../tools/qemu.zig" );
const util = @import( "../tools/buildUtil.zig" );
const SymlinkStep = @import( "../tools/symlinkStep.zig" );
const PackagesStep = @import( "../tools/packagesStep.zig" );

pub fn register( packages: *PackagesStep ) void {
	packages.registerPackage( "sbase", build );
}

pub fn build( b: *std.Build, target: std.Target, packages: *PackagesStep ) anyerror!void {
	const libc = packages.getStep( "musl" ).?;

	const sbasePrep = b.addSystemCommand( &.{
		"sh", "-c",
		"cp -a ./vendor/sbase/ $1"
			++ " && cp -al $1 $2"
			++ " && mkdir $3"
			++ " && cp -l $1/*.1 $3",
		"zig-build"
	} );
	const sbasePrepDyn = sbasePrep.addOutputFileArg( "sbase-dyn" );
	const sbasePrepStatic = sbasePrep.addOutputFileArg( "sbase-static" );
	const sbaseManInstall = b.addInstallDirectory( .{
		.source_dir = sbasePrep.addOutputFileArg( "man" ),
		.install_dir = .prefix,
		.install_subdir = "usr/share/man/man1/"
	} );
	sbasePrep.setName( "run sh (sbase prepare)" );
	sbasePrep.extra_file_dependencies = try util.findByExt( b.allocator, "vendor/sbase/", ".c", false );

	const sbaseDyn = b.addSystemCommand( &.{
		"sh", "-c",
		"cd $1"
			++ " && make clean"
			++ " && make -sj sbase-box"
			++ " && patchelf"
				++ " --set-interpreter /lib/libc.so"
				++ " --replace-needed ../../../../zig-out/lib/libc.so libc.so"
				++ " --output $2"
				++ " ./sbase-box",
		"zig-build"
	} );
	sbaseDyn.addDirectoryArg( sbasePrepDyn );
	const sbaseDynInstall = b.addInstallBinFile( sbaseDyn.addOutputFileArg( "sbase-box-dynamic" ), "sbase-box-dynamic" );
	sbaseDyn.step.dependOn( libc );
	util.setCcEnv( sbaseDyn, target.cpu.arch, .dynamic, "../../../..", .{
		.CFLAGS = "-include ../../../../zig-out/include/limits.h",
		.LDFLAGS = "-lc"
	} );

	const sbaseStatic = b.addSystemCommand( &.{
		"sh", "-c",
		"cd $1"
			++ " && make clean"
			++ " && make -sj sbase-box"
			++ " && cp -l $1/sbase-box $2",
		"zig-build"
	} );
	sbaseStatic.addDirectoryArg( sbasePrepStatic );
	const sbaseStaticInstall = b.addInstallBinFile( sbaseStatic.addOutputFileArg( "sbase-box-static" ), "sbase-box-static" );
	sbaseStatic.step.dependOn( libc );
	util.setCcEnv( sbaseStatic, target.cpu.arch, .static, "../../../..", .{
		.CFLAGS = "-include ../../../../zig-out/include/limits.h",
		.LDFLAGS = "../../../../zig-out/lib/libc.a ../../../../zig-out/lib/crt1.o"
	} );

	var sbase = SymlinkStep.create( b, &.{ .{ "./zig-out/bin/sbase-box", "sbase-box-static" } } );
	sbase.step.name = "install sbase";
	sbase.step.dependOn( &sbaseDynInstall.step );
	sbase.step.dependOn( &sbaseStaticInstall.step );
	sbase.step.dependOn( &sbaseManInstall.step );

	packages.registerStep( "sbase", &sbase.step );
}

test "sbase.static.echo" {
	try qemu.runElfTest(
		&.{},
		"/bin/sbase-box-static",
		"/bin/echo test multiline\nstring",
		"test multiline\r\nstring\r\n"
	);
}

test "sbase.dynamic.echo" {
	try qemu.runElfTest(
		&.{},
		"/bin/sbase-box-dynamic",
		"/bin/echo test multiline\nstring",
		"test multiline\r\nstring\r\n"
	);
}

test "sbase.static.date" {
	try qemu.runElfTest(
		&.{ "-rtc", "base=2023-02-01T01:02:03" },
		"/bin/sbase-box-static",
		"/bin/date",
		"Wed Feb  1 01:02:03 UTC 2023\r\n"
	);
}

test "sbase.dynamic.date" {
	try qemu.runElfTest(
		&.{ "-rtc", "base=2023-02-01T01:02:03" },
		"/bin/sbase-box-dynamic",
		"/bin/date",
		"Wed Feb  1 01:02:03 UTC 2023\r\n"
	);
}
