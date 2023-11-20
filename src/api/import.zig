const std = @import( "std" );

pub const panic = @import( "./panic.zig" ).panic;
pub const os = struct {
	pub const system = @import( "./system.zig" );
};

export fn _start( argc: usize, argv: [*][*:0]u8 ) void {
	std.os.argv = argv[0..argc];
	@import( "root" ).main() catch |err| @panic( @errorName( err ) );
	std.os.system.exit( 0 );
}
