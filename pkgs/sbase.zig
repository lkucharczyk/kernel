const std = @import( "std" );
const qemu = @import( "../tools/qemu.zig" );
const util = @import( "../tools/buildUtil.zig" );
const SymlinkStep = @import( "../tools/symlinkStep.zig" );
const PackagesStep = @import( "../tools/packagesStep.zig" );

pub const BINARIES_SBASE = [_][:0]const u8{
	"basename", "cal", "cat", "chgrp", "chmod", "chown", "chroot", "cksum", "cmp", "cols", "comm",
	"cp", "cron", "cut", "date", "dd", "dirname", "du", "echo", "ed", "env", "expand", "expr",
	"false", "find", "flock", "fold", "getconf", "grep", "head", "hostname", "join", "kill",
	"link", "ln", "logger", "logname", "ls", "md5sum", "mkdir", "mkfifo", "mknod", "mktemp", "mv",
	"nice", "nl", "nohup", "od", "paste", "pathchk", "printenv", "printf", "pwd", "readlink",
	"renice", "rev", "rm", "rmdir", "sed", "seq", "setsid", "sha1sum", "sha224sum", "sha256sum",
	"sha384sum", "sha512-224sum", "sha512-256sum", "sha512sum", "sleep", "sort", "split", "sponge",
	"strings", "sync", "tail", "tar", "tee", "test", "tftp", "time", "touch", "tr", "true",
	"tsort", "tty", "uname", "unexpand", "uniq", "unlink", "uudecode", "uuencode", "wc", "which",
	"whoami", "xargs", "xinstall", "yes"
};

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
	} );

	const symlinks = comptime _: {
		var symlinks: [BINARIES_SBASE.len + 1][2][]const u8 = undefined;
		symlinks[0] = .{ "./zig-out/bin/sbase-box", "sbase-box-static" };

		for ( BINARIES_SBASE, 1.. ) |bin, i| {
			symlinks[i] = .{ "./zig-out/bin/" ++ bin, "sbase-box" };
		}

		break :_ symlinks;
	};

	var sbase = SymlinkStep.create( b, &symlinks );
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

test "sbase.static.env" {
	try qemu.runElfTest(
		&.{},
		"/bin/sbase-box-static",
		"/bin/env A=1 B=2",
		"A=1\r\nB=2\r\n"
	);
}

test "sbase.dynamic.env" {
	try qemu.runElfTest(
		&.{},
		"/bin/sbase-box-dynamic",
		"/bin/env A=1 B=2",
		"A=1\r\nB=2\r\n"
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
