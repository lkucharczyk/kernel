const std = @import( "std" );

pub fn findByExt( alloc: std.mem.Allocator, prefix: []const u8, ext: []const u8, symlinks: bool ) ![][]const u8 {
	var out = std.ArrayList( []const u8 ).init( alloc );
	defer out.deinit();

	var dir = try std.fs.cwd().openDir( prefix, .{ .iterate = true } );
	defer dir.close();

	var walker = try dir.walk( alloc );
	defer walker.deinit();

	while ( try walker.next() ) |e| {
		switch ( e.kind ) {
			.file,
			.sym_link => {
				if ( ( e.kind == .file or symlinks ) and std.mem.endsWith( u8, e.basename, ext ) ) {
					const path = try alloc.alloc( u8, prefix.len + e.path.len );
					@memcpy( path[0..prefix.len], prefix );
					@memcpy( path[prefix.len..], e.path );
					try out.append( path );
				}
			},
			else => {}
		}
	}

	return try out.toOwnedSlice();
}

pub fn setCcEnv(
	step: *std.Build.Step.Run,
	_: std.Target.Cpu.Arch,
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
					.static => "-static -target x86-linux-none",
				} else (
					"-target x86-linux-none"
				)
			)
			++ " -ffreestanding -nostdinc -nostdlib -march=pentium4"
			++ " -isystem" ++ sysroot ++ "/include/"
			++ " -isysroot" ++ sysroot ++ "/"
			++ " -L" ++ sysroot ++ "/lib/"
	);

	step.setEnvironmentVariable(
		"LDFLAGS",
		( if ( linkage == .dynamic ) "-dynamic-linker " ++ sysroot ++ "/lib/libc.so" else "" )
			++ ( if ( @hasField( otherT, "LDFLAGS" ) ) " " ++ other.LDFLAGS else "" )
	);

	inline for ( @typeInfo( otherT ).Struct.fields ) |f| {
		if ( !std.mem.eql( u8, f.name, "CC" ) and !std.mem.eql( u8, f.name, "LDFLAGS" ) ) {
			step.setEnvironmentVariable( f.name, @field( other, f.name ) );
		}
	}
}
