const std = @import( "std" );
const util = @import( "./buildUtil.zig" );

pub const Options = struct {
	const InitRd = union(enum) {
		custom: []const u8,
		load
	};

	arch: std.Target.Cpu.Arch,
	headless: bool = false,
	initrd: InitRd = .load,
	mem: usize = 1024,
	net: bool = false,
	noShutdown: bool = true
};

pub fn getBin( arch: std.Target.Cpu.Arch ) []const u8 {
	return switch ( arch ) {
		.x86     => "qemu-system-i386",
		.x86_64  => "qemu-system-x86_64",
		else     => unreachable
	};
}

pub fn getCmd( alloc: std.mem.Allocator, options: Options ) anyerror![][]const u8 {
	var args = try std.ArrayList( []const u8 ).initCapacity( alloc, 32 );
	try args.appendSlice( &.{
		getBin( options.arch ),
		"-kernel", "./zig-out/bin/kernel.elf",
		"-device", "isa-debug-exit",
		"-parallel", "none",
		"-no-reboot",
		"-m", try std.fmt.allocPrint( alloc, "{}M", .{ options.mem } )
	} );

	if ( options.headless ) {
		try args.appendSlice( &.{
			"-display", "none",
			"-monitor", "none",
			"-vga", "none",
			"-serial", "stdio"
		} );
	} else {
		try args.appendSlice( &(
			.{ "-vga", "virtio" }
				++ ( .{ "-serial", "vc" } ** 4 )
		) );
	}

	if ( options.net ) {
		try args.appendSlice( &.{
			"-nic", "tap,id=n0,model=rtl8139,ifname=tap0,script=no,downscript=no",
			"-nic", "tap,id=n1,model=rtl8139,ifname=tap1,script=no,downscript=no"
		} );
	}

	if ( options.noShutdown ) {
		try args.append( "-no-shutdown" );
	}

	try args.append( "-initrd" );
	try args.append(
		switch ( options.initrd ) {
			.custom => |c| c,
			.load => try std.mem.join( alloc, ",", try util.findByExt( alloc, "./zig-out/", "", true ) ),
		}
	);

	return try args.toOwnedSlice();
}

pub fn runElfTest(
	qemuArgs: []const []const u8,
	comptime bin: []const u8,
	comptime binArgs: []const u8,
	expected: []const u8
) anyerror!void {
	var arena = std.heap.ArenaAllocator.init( std.testing.allocator );
	const alloc = arena.allocator();
	defer arena.deinit();

	var args = std.ArrayList( []const u8 ).fromOwnedSlice( alloc, try getCmd( alloc, .{
		.arch = @import( "builtin" ).target.cpu.arch,
		.headless = true,
		.net = false,
		.noShutdown = false,
		.initrd = .{
			.custom = "./zig-out/kernel.dbg,"
				++ "./zig-out/bin/sbase-box-dynamic,"
				++ "./zig-out/bin/sbase-box-static /bin/sbase-box,"
				++ "./zig-out/lib/libc.so /lib/ld-musl-i386.so.1 /lib/ld-musl-x86.so.1"
		}
	} ) );

	try args.appendSlice( qemuArgs );
	try args.append( "-append" );
	try args.append( "--test " ++ bin ++ " " ++ binArgs );

	var process = std.process.Child.init( try args.toOwnedSlice(), alloc );
	defer alloc.free( process.argv );

	var stdout = try std.ArrayList( u8 ).initCapacity( alloc, expected.len );
	defer stdout.deinit();
	var stderr = std.ArrayList( u8 ).init( alloc );
	defer stderr.deinit();

	process.stdin_behavior = .Pipe;
	process.stdout_behavior = .Pipe;
	process.stderr_behavior = .Pipe;
	try process.spawn();
	try process.collectOutput( &stdout, &stderr, expected.len + 1024 );
	_ = try process.wait();

	try std.testing.expectEqualStrings( "", stderr.items );
	try std.testing.expectEqualStrings( expected, stdout.items );
}
