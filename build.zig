const std = @import( "std" );
const qemu = @import( "./tools/qemu.zig" );
const util = @import( "./tools/buildUtil.zig" );
const PackagesStep = @import( "./tools/packagesStep.zig" );

fn getQemu( b: *std.Build, arch: std.Target.Cpu.Arch, comptime debug: bool ) anyerror!*std.Build.Step.Run {
	return b.addSystemCommand( &.{
		"sh", "-c",
		try std.mem.concat( b.allocator, u8, &.{
			try std.mem.join( b.allocator, " ", try qemu.getCmd( b.allocator, .{
				.arch = arch,
				.net = true,
				.initrd = .{ .custom = "\"$(find zig-out/ -type f -exec sh -c 'echo ./{} $(find -L zig-out -xtype l -samefile {} | cut -c8-)' \\; | paste -sd ',' -)\"" }
			} ) ),
			( if ( debug ) ( " -s -S" ) else ( " -s" ) )
				++ " -d int"
				++ " 2>&1"
				++ "| grep -A10 -E '^(check_exception|qemu-system)'"
		} )
	} );
}

pub fn build( b: *std.Build ) !void {
	const arch: std.Target.Cpu.Arch = .x86;
	const optimize = b.standardOptimizeOption( .{} );
	const target = b.resolveTargetQuery( .{
		.cpu_arch = arch,
		.cpu_model = .{ .explicit = &std.Target.x86.cpu.pentium4 },
		.abi = .none,
		.os_tag = .freestanding
	} );

	const kernel = b.addExecutable( .{
		.name = "kernel.elf",
		.root_source_file = .{ .path = "src/main.zig" },
		.single_threaded = true,
		.linkage = .static,
		.target = target,
		.optimize = optimize
	} );
	kernel.compress_debug_sections = .zlib;
	kernel.setLinkerScript( .{ .path = "src/linker.ld" } );

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

	const packages = PackagesStep.create( b, target.result );
	@import( "./pkgs/musl.zig" ).register( packages );
	@import( "./pkgs/sbase.zig" ).register( packages );
	@import( "./pkgs/simplechat.zig" ).register( packages );
	packages.select( b.option( []const u8, "packages", "Add packages to the installation" ) orelse "sbase" );
	b.getInstallStep().dependOn( &packages.step );

	const embedSymbols = b.addSystemCommand( &.{
		"sh", "-c",
		"cp $1 $2"
			++ " && objdump -t $1"
			++ " | tail -n+5"
			++ " | head -n-2"
			++ " | grep -E '^[0-9a-f]+ .{6}[fF]'"
			++ " | sed -nr 's/^([0-9a-f]+).*?\\t([0-9a-f]+) (.+)$/\\1 \\2 \\3/p'"
			++ " | sort"
			// ++ " | tee ./zig-cache/symbolmap.txt"
			++ " | grep -vP '\\d\\.stub|__'"
			++ " | sed -r '"
				++ "s/\\.\\{\\.[a-z][^}]+\\}/.{ ... }/g;"
				++ "s/error\\{[^}]+\\}/error{ ... }/g;"
				++ "s/\\(function /(fn /g;"
				++ "s/(multi_)?array_(hash_map|list)\\.(Multi)?Array/\\3Array/g;"
				++ "s/hash_map\\.(HashMap)/\\1/g;"
				++ "s/linked_list\\.(Singly|Doubly)/\\1/g;"
				++ "s/heap\\.[a-z_]+_allocator\\.([A-Za-z_]+Allocator)/heap.\\1/g;"
				++ "s/heap\\.memory_pool\\.MemoryPool/heap.MemoryPool/g;"
				++ "s/io\\.[a-z_]+_reader\\.([A-Za-z_]+Reader)/io.\\1/g;"
				++ "s/io\\.[a-z_]+_stream\\.([A-Za-z_]+Stream)/io.\\1/g'"
			// ++ " | tee ./zig-cache/symbolmap-filtered.txt"
			++ " | LC_CTYPE=c awk '{" ++
				\\ for ( i = 0; i < 4; ++i ) {
				\\     printf( "%c", strtonum( "0x" substr( $1, 1 + 2 * i, 2 ) ) );
				\\ }
				\\ for ( i = 0; i < 4; ++i ) {
				\\     printf( "%c", strtonum( "0x" substr( $2, 1 + 2 * i, 2 ) ) );
				\\ }
				\\ print substr( $0, 19 );
			++ "}'"
			// ++ " | tee ./zig-cache/symbolmap.bin"
			++ " | dd of=$2 oflag=seek_bytes conv=notrunc oseek=$("
				++ "objdump -x $1"
				++ " | grep symbolTable"
				++ " | awk '{ print strtonum( \"0x\" $1 ) - 0xc0100000 + 0x1000 }'"
			++ ")"
			++ " 2> /dev/null",
		"zig-build"
	} );
	embedSymbols.addFileArg( kernel.getEmittedBin() );
	b.getInstallStep().dependOn(
		&b.addInstallBinFile( embedSymbols.addOutputFileArg( "kernel.elf" ), "kernel.elf" ).step
	);

	const genSymbols = b.addSystemCommand( &.{ "zig", "objcopy", "--only-keep-debug" } );
	genSymbols.addFileArg( kernel.getEmittedBin() );
	b.getInstallStep().dependOn(
		&b.addInstallFile( genSymbols.addOutputFileArg( "kernel.dbg" ), "kernel.dbg" ).step
	);

	const qemuRun = try getQemu( b, arch, false );
	qemuRun.step.dependOn( b.getInstallStep() );
	const run = b.step( "run", "Run kernel in QEMU" );
	run.dependOn( &qemuRun.step );

	const qemuDebug = try getQemu( b, arch, true );
	qemuDebug.step.dependOn( b.getInstallStep() );
	const runDebug = b.step( "debug", "Run kernel in QEMU (w/ GDB)" );
	runDebug.dependOn( &qemuDebug.step );

	const tests = b.addSystemCommand( &.{ "sh", "-c", "zig test ./build.zig 2>&1 | cat" } );
	tests.step.dependOn( b.getInstallStep() );
	const testsStep = b.step( "test", "Run tests" );
	testsStep.dependOn( &tests.step );

	const libcClean = b.addSystemCommand( &.{ "make", "clean" } );
	libcClean.setCwd( .{ .path = "./vendor/musl/" } );
	b.getUninstallStep().dependOn( &libcClean.step );
	const sbaseClean = b.addSystemCommand( &.{ "make", "clean" } );
	sbaseClean.setCwd( .{ .path = "./vendor/sbase/" } );
	b.getUninstallStep().dependOn( &sbaseClean.step );
	b.getUninstallStep().dependOn(
		&b.addSystemCommand( &.{ "sh", "-c", "rm -rf ./vendor/musl/config.mak ./zig-cache/* ./zig-out/*" } ).step
	);
}

comptime {
	std.testing.refAllDecls( @This() );
}
