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
			++ " -vga virtio"
			++ " -device isa-debug-exit"
			++ " -serial vc"
			++ " -serial vc"
			++ " -nic tap,id=n0,model=rtl8139,ifname=tap0,script=no,downscript=no"
			++ " -nic tap,id=n1,model=rtl8139,ifname=tap1,script=no,downscript=no"
			++ " -no-reboot -no-shutdown"
			++ " -d int"
			++ ( if ( debug ) ( " -s -S" ) else ( " -s" ) )
			++ " 2>&1"
			++ "| grep -A10 ^check_exception"
	} );

	return qemu;
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
	kernel.linkage = .static;
	kernel.setLinkerScript( .{ .path = "src/linker.ld" } );
	b.installArtifact( kernel );

	const embedSymbols = b.addSystemCommand( &.{
		"sh", "-c",
		"objdump -t ./zig-out/bin/kernel.elf"
			++ "| tail -n+5"
			++ "| head -n-2"
			++ "| sed -nr 's/^([0-9a-f]+).*?\\t([0-9a-f]+) (.+)$/\\1 \\2 \\3/p'"
			++ "| sort"
			++ "| tee ./zig-cache/symbolmap.txt"
			++ "| grep -vP '__anon_\\d+|\\d+\\.stub'"
			++ "| sed -r 's/Allocator\\(\\.\\{[^}]+\\}\\)/Allocator(.{ ... })/'"
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
	embedSymbols.step.dependOn( b.getInstallStep() );

	const qemu = getQemu( b, arch, false );
	qemu.step.dependOn( &embedSymbols.step );
	const run = b.step( "run", "Run kernel in QEMU" );
	run.dependOn( &qemu.step );

	const qemuDebug = getQemu( b, arch, true );
	qemuDebug.step.dependOn( &embedSymbols.step );
	const runDebug = b.step( "debug", "Run kernel in QEMU (w/ GDB)" );
	runDebug.dependOn( &qemuDebug.step );
}
