const std = @import( "std" );

pub const panic = @import( "./panic.zig" ).panic;
pub const os = struct {
	pub const heap = struct {
		var sbrk_allocator = std.heap.SbrkAllocator( system.sbrk ) {};
		pub const page_allocator = std.mem.Allocator {
			.ptr = &sbrk_allocator,
			.vtable = &@TypeOf( sbrk_allocator ).vtable
		};
	};
	pub const system = @import( "./system.zig" );
};

var _argptr: [*]usize = undefined;

export fn _start() callconv(.Naked) noreturn {
	asm volatile (
		\\ movl %%esp, %[argptr]
		\\ calll %[start:P]
		: [argptr] "=m" ( _argptr )
		: [start] "X" ( &_start2 )
	);
}

fn _start2() callconv(.C) void {
	std.os.argv = @as( [*][*:0]u8, @ptrCast( _argptr[1..] ) )[0.._argptr[0]];
	@import( "root" ).main() catch |err| @panic( @errorName( err ) );
	std.os.system.exit( 0 );
}
