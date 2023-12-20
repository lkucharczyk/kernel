const std = @import( "std" );

fn getQemu( b: *std.Build, comptime arch: std.Target.Cpu.Arch, comptime debug: bool ) *std.Build.Step.Run {
	const bin = switch ( arch ) {
		.x86     => "qemu-system-i386",
		.x86_64  => "qemu-system-x86_64",
		else     => unreachable
	};

	const qemu = b.addSystemCommand( &.{
		"sh", "-c",
		bin
			++ " -kernel ./zig-out/bin/kernel.elf"
			++ " -initrd \""
				++ "./zig-out/kernel.dbg,"
				++ "./zig-out/bin/sbase-box-dynamic,"
				++ "./zig-out/bin/sbase-box-static /bin/sbase-box,"
				++ "./zig-out/bin/shell,"
				++ "./zig-out/lib/libc.so /lib/ld-musl-i386.so.1 /lib/ld-musl-x86.so.1,"
				++ "./vendor/sbase/cat.c /src/sbase/cat.c"
				++ "\""
			++ " -m 512M"
			++ " -vga virtio"
			++ " -device isa-debug-exit"
			++ ( " -serial vc" ** 4 )
			++ " -parallel none"
			++ " -nic tap,id=n0,model=rtl8139,ifname=tap0,script=no,downscript=no"
			++ " -nic tap,id=n1,model=rtl8139,ifname=tap1,script=no,downscript=no"
			++ " -no-reboot -no-shutdown"
			++ " -d int"
			++ ( if ( debug ) ( " -s -S" ) else ( " -s" ) )
			++ " 2>&1"
			++ "| grep -A10 -E '^(check_exception|qemu-system)'"
	} );

	return qemu;
}

fn setCcEnv(
	step: *std.Build.Step.Run,
	comptime _: std.Target.Cpu.Arch,
	comptime linkage: ?std.Build.Step.Compile.Linkage,
	comptime prefix: []const u8,
	comptime other: anytype
) void {
	const otherT = @TypeOf( other );
	const sysroot = prefix ++ "/zig-out";

	step.setEnvironmentVariable( "AR", "zig ar" );
	step.setEnvironmentVariable( "RANLIB", "zig ranlib" );
	step.setEnvironmentVariable(
		"CC",
		"zig cc "
			++ (
				if ( linkage ) |l| switch ( l ) {
					.dynamic => "-dynamic -target x86-linux-musl -fPIC",
					.static => "-static -target x86-freestanding-none",
				} else (
					"-target x86-freestanding-none"
				)
			)
			++ " -ffreestanding -nostdinc -nostdlib -march=i386"
			++ " -isystem" ++ sysroot ++ "/include/"
			++ " -isysroot" ++ sysroot ++ "/"
			++ " -L" ++ sysroot ++ "/lib/"
	);

	step.setEnvironmentVariable(
		"LDFLAGS",
		( if ( linkage == .dynamic ) "-dynamic-linker " ++ sysroot ++ "/lib/libc.so -z notext" else "" )
			++ ( if ( @hasField( otherT, "LDFLAGS" ) ) " " ++ other.LDFLAGS else "" )
	);

	inline for ( @typeInfo( otherT ).Struct.fields ) |f| {
		if ( !std.mem.eql( u8, f.name, "CC" ) and !std.mem.eql( u8, f.name, "LDFLAGS" ) ) {
			step.setEnvironmentVariable( f.name, @field( other, f.name ) );
		}
	}
}

pub fn build( b: *std.Build ) !void {
	const arch: std.Target.Cpu.Arch = .x86;
	const optimize = b.standardOptimizeOption( .{
		.preferred_optimize_mode = .Debug
	} );
	const target = std.zig.CrossTarget {
		.cpu_arch = arch,
		.cpu_model = .{ .explicit = std.Target.Cpu.Model.generic( .x86 ) },
		.abi = .none,
		.os_tag = .freestanding
	};

	const kernel = b.addExecutable( .{
		.name = "kernel.elf",
		.root_source_file = .{ .path = "src/main.zig" },
		.single_threaded = true,
		.linkage = .static,
		.target = target,
		.optimize = optimize
	} );
	kernel.code_model = .kernel;
	kernel.compress_debug_sections = .zlib;
	kernel.setLinkerScript( .{ .path = "src/linker.ld" } );
	b.installArtifact( kernel );

	const shell = b.addExecutable( .{
		.name = "shell",
		.root_source_file = .{ .path = "src/shell.zig" },
		.single_threaded = true,
		.linkage = .static,
		.target = target,
		.optimize = optimize
	} );
	shell.compress_debug_sections = .zlib;
	b.installArtifact( shell );

	var libcConfig = b.addSystemCommand( &.{
		"sh", "-c",
		"LIBCC=$(clang -target i386-linux --rtlib=compiler-rt -print-libgcc-file-name) ./configure"
			++ " --target=i386-freestanding-none"
			++ " --prefix=../../zig-out/"
			++ " --syslibdir=../../zig-out/lib"
	} );
	libcConfig.setCwd( .{ .path = "vendor/musl/" } );
	setCcEnv( libcConfig, arch, null, "../..", .{} );

	const libc = b.addSystemCommand( &.{ "make", "-j", "install" } );
	libc.setCwd( .{ .path = "vendor/musl/" } );
	if ( ( std.fs.cwd().statFile( "./vendor/musl/config.mak" ) catch null ) == null ) {
		libc.step.dependOn( &libcConfig.step );
	}
	b.getInstallStep().dependOn( &libc.step );

	const sbaseDyn = b.addSystemCommand( &.{
		"sh", "-c",
		"make clean"
			++ "&& make -j sbase-box"
			++ "&& patchelf"
				++ " --set-interpreter /lib/ld-musl-i386.so.1"
				++ " --replace-needed ../../zig-out/lib/libc.so /lib/libc.so"
				++ " --output ../../zig-out/bin/sbase-box-dynamic"
				++ " ./sbase-box"
	} );
	sbaseDyn.step.dependOn( &libc.step );
	sbaseDyn.setCwd( .{ .path = "vendor/sbase/" } );
	setCcEnv( sbaseDyn, arch, .dynamic, "../..", .{
		.CFLAGS = "-include ../../zig-out/include/limits.h",
		.LDFLAGS = "-lc"
	} );

	const sbaseStatic = b.addSystemCommand( &.{
		"sh", "-c",
		"make clean"
			++ "&& make -j sbase-box"
			++ "&& cp ./sbase-box ../../zig-out/bin/sbase-box-static"
	} );
	sbaseStatic.step.dependOn( &libc.step );
	sbaseStatic.setCwd( .{ .path = "vendor/sbase/" } );
	setCcEnv( sbaseStatic, arch, .static, "../..", .{
		.CFLAGS = "-include ../../zig-out/include/limits.h",
		.LDFLAGS = "../../zig-out/lib/libc.a ../../zig-out/lib/crt1.o"
	} );

	if ( ( std.fs.cwd().access( "./zig-out/bin/sbase-box-dynamic", .{} ) catch null ) == null ) {
		b.getInstallStep().dependOn( &sbaseDyn.step );
		sbaseStatic.step.dependOn( &sbaseDyn.step );
	}
	if ( ( std.fs.cwd().access( "./zig-out/bin/sbase-box-static", .{} ) catch null ) == null ) {
		b.getInstallStep().dependOn( &sbaseStatic.step );
	}

	const embedSymbols = b.addSystemCommand( &.{
		"sh", "-c",
		"objdump -t ./zig-out/bin/kernel.elf"
			++ "| tail -n+5"
			++ "| head -n-2"
			++ "| grep -E '^[0-9a-f]+ .{6}[fF]'"
			++ "| sed -nr 's/^([0-9a-f]+).*?\\t([0-9a-f]+) (.+)$/\\1 \\2 \\3/p'"
			++ "| sort"
			++ "| tee ./zig-cache/symbolmap.txt"
			++ "| grep -vP '__anon_\\d+|\\d+\\.stub|hash_map|__zig'"
			++ "| sed -r 's/Allocator\\(\\.\\{[^}]+\\}\\)/Allocator(.{ ... })/'"
			++ "| sed -r 's/MemoryPoolExtra\\(([^,]+),\\.\\{[^}]+\\}\\)/MemoryPoolExtra(\\1,.{ ... })/'"
			++ "| tee ./zig-cache/symbolmap-filtered.txt"
			++ "| LC_CTYPE=c awk '{" ++
				\\ for ( i = 0; i < 4; ++i ) {
				\\     printf( "%c", strtonum( "0x" substr( $1, 1 + 2 * i, 2 ) ) );
				\\ }
				\\ for ( i = 0; i < 4; ++i ) {
				\\     printf( "%c", strtonum( "0x" substr( $2, 1 + 2 * i, 2 ) ) );
				\\ }
				\\ print substr( $0, 19 );
			++ "}'"
			++ "| tee ./zig-cache/symbolmap.bin"
			++ "| dd of=./zig-out/bin/kernel.elf oflag=seek_bytes conv=notrunc oseek=$("
				++ "objdump -x zig-out/bin/kernel.elf"
				++ "| grep symbolTable"
				++ "| awk '{ print strtonum( \"0x\" $1 ) - 0xc0100000 + 0x1000 }'"
			++ ")"
	} );
	embedSymbols.step.dependOn( &kernel.step );
	b.getInstallStep().dependOn( &embedSymbols.step );

	const genSymbols = b.addSystemCommand( &.{
		"objcopy", "--only-keep-debug", "./zig-out/bin/kernel.elf", "./zig-out/kernel.dbg"
	} );
	genSymbols.step.dependOn( &kernel.step );
	b.getInstallStep().dependOn( &genSymbols.step );

	const qemu = getQemu( b, arch, false );
	qemu.step.dependOn( b.getInstallStep() );
	const run = b.step( "run", "Run kernel in QEMU" );
	run.dependOn( &qemu.step );

	const qemuDebug = getQemu( b, arch, true );
	qemuDebug.step.dependOn( b.getInstallStep() );
	const runDebug = b.step( "debug", "Run kernel in QEMU (w/ GDB)" );
	runDebug.dependOn( &qemuDebug.step );

	const libcClean = b.addSystemCommand( &.{ "make", "clean" } );
	libcClean.setCwd( .{ .path = "./vendor/musl/" } );
	b.getUninstallStep().dependOn( &libcClean.step );
	const sbaseClean = b.addSystemCommand( &.{ "make", "clean" } );
	sbaseClean.setCwd( .{ .path = "./vendor/sbase/" } );
	b.getUninstallStep().dependOn( &sbaseClean.step );
	b.getUninstallStep().dependOn( &b.addSystemCommand( &.{ "rm", "vendor/musl/config.mak" } ).step );
	b.getUninstallStep().dependOn( &b.addSystemCommand( &.{ "rm", "-rf", "zig-out/" } ).step );
}
