pub const State = extern struct {
	gs: u32,
	fs: u32,
	es: u32,
	ds: u32,

	edi: u32,
	esi: u32,
	ebp: u32,
	esp: u32,
	ebx: u32,
	edx: u32,
	ecx: u32,
	eax: u32,

	intNum: u32,
	errNum: i32,

	eip: u32,
	cs: u32,
	eflags: u32,
	uesp: u32,
	ss: u32
};

pub const StackPtr = extern struct {
	esp: u32,
	ebp: u32,

	pub inline fn get() StackPtr {
		return .{
			.esp = asm volatile ( "" : [_] "={esp}" ( -> u32 ) ),
			.ebp = asm volatile ( "" : [_] "={ebp}" ( -> u32 ) )
		};
	}

	pub inline fn set( self: StackPtr ) void {
		asm volatile ( "" :: [esp] "{esp}" ( self.esp ), [_] "{ebp}" ( self.ebp ) );
	}
};

pub const TablePtr = extern struct {
	limit: u16 align(1),
	base: u32 align(1),

	pub fn init( comptime T: anytype, comptime S: comptime_int, ptr: *const [S]T ) TablePtr {
		return .{
			.limit = @sizeOf( T ) * S - 1,
			.base = @intFromPtr( ptr )
		};
	}
};

pub inline fn enableInterrupts() void {
	asm volatile ( "sti" );
}

pub inline fn disableInterrupts() void {
	asm volatile ( "cli" );
}

pub inline fn halt() noreturn {
	disableInterrupts();

	for ( 0..100 ) |_| {
		asm volatile ( "nop" );
	}

	while ( true ) {
		asm volatile ( "hlt" );
	}
}

pub inline fn in( comptime T: type, port: u16 ) T {
	return @bitCast( switch ( @bitSizeOf( T ) ) {
		8 => asm volatile (
			"inb %[port], %[val]"
			: [val] "={al}" ( -> u8 )
			: [port] "{dx}" ( port )
			: "memory"
		),
		16 => asm volatile (
			"inw %[port], %[val]"
			: [val] "={ax}" ( -> u16 )
			: [port] "{dx}" ( port )
			: "memory"
		),
		32 => asm volatile (
			"inl %[port], %[val]"
			: [val] "={eax}" ( -> u32 )
			: [port] "{dx}" ( port )
			: "memory"
		),
		else => @compileError( "Invalid value size" )
	} );
}

pub inline fn out( comptime T: type, port: u16, val: T ) void {
	switch ( @bitSizeOf( T ) ) {
		8 => asm volatile (
			"outb %[val], %[port]"
			:: [val]  "{al}" ( @as( u8, @bitCast( val ) ) ),
			   [port] "{dx}" ( port )
			: "memory"
		),
		16 => asm volatile (
			"outw %[val], %[port]"
			:: [val]  "{ax}" ( @as( u16, @bitCast( val ) ) ),
			   [port] "{dx}" ( port )
			: "memory"
		),
		32 => asm volatile (
			"outl %[val], %[port]"
			:: [val] "{eax}" ( @as( u32, @bitCast( val ) ) ),
			   [port] "{dx}" ( port )
			: "memory"
		),
		else => @compileError( "Invalid value size" )
	}
}

pub inline fn saveState( comptime inInt: bool ) void {
	if ( !inInt ) {
		asm volatile (
			\\ pushl %%eax
			\\ pushl %%eax
		);
	}

	asm volatile (
		\\ pusha
		\\ push %%ds
		\\ push %%es
		\\ push %%fs
		\\ push %%gs
		\\ mov $0x10, %%ax
		\\ mov %%ax, %%ds
		\\ mov %%ax, %%es
		\\ mov %%ax, %%fs
		\\ mov %%ax, %%gs
		\\ mov %%esp, %%eax
		\\ pushl %%eax
	);
}

pub inline fn restoreState() void {
	asm volatile (
		\\ popl %%eax
		\\ popl %%gs
		\\ popl %%fs
		\\ popl %%es
		\\ popl %%ds
		\\ popa
		\\ popl %%eax
		\\ popl %%eax
	);
}
