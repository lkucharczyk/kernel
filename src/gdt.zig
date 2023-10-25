const std = @import( "std" );
const x86 = @import( "./x86.zig" );

pub const Entry = packed struct(u64) {
	pub const Access = packed struct(u8) {
		const KERNEL_CODE = Access {
			.rw = true,
			.executable = true,
			.descriptorType = true,
			.present = true
		};

		const KERNEL_DATA = Access {
			.rw = true,
			.executable = false,
			.descriptorType = true,
			.present = true
		};

		const USER_CODE = Access {
			.rw = true,
			.executable = true,
			.descriptorType = true,
			.ring = 3,
			.present = true
		};

		const USER_DATA = Access {
			.rw = true,
			.executable = false,
			.descriptorType = true,
			.ring = 3,
			.present = true
		};

		const TSS = Access {
			.accessed = true,
			.executable = true,
			.descriptorType = false,
			.present = true
		};

		accessed: bool = false,
		rw: bool = false,
		/// false - limit > offset
		/// true  - limit < offset
		direction: bool = false,
		executable: bool = false,
		/// false - TSS
		/// true  - code/data segment
		descriptorType: bool = true,
		ring: u2 = 0,
		present: bool = false,
	};

	pub const Granularity = packed struct(u4) {
		_: u1 = 0,
		longMode: bool = false,
		protectedMode: bool = true,
		paging: bool = true
	};

	limitLow: u16,
	baseLow: u16,
	baseMiddle: u8,
	access: Access,
	limitHigh: u4,
	granularity: Granularity,
	baseHigh: u8,

	pub fn set( self: *Entry, base: u32, limit: u20, access: Access, granularity: Granularity ) void {
		self.limitLow  = @truncate( limit );
		self.limitHigh = @truncate( limit >> 16 );

		self.baseLow    = @truncate( base );
		self.baseMiddle = @truncate( base >> 16 );
		self.baseHigh   = @truncate( base >> 24 );

		self.access = access;
		self.granularity = granularity;
	}

	pub fn unset( self: *Entry ) void {
		self.access.present = false;
	}
};

pub const Tss = extern struct {
	link:   u16 align(1) = 0,
	_0:     u16 align(1) = 0,
	esp0:   u32 align(1) = 0,
	ss0:    u16 align(1) = 2 << 3,
	_1:     u16 align(1) = 0,
	esp1:   u32 align(1) = 0,
	ss1:    u16 align(1) = 0,
	_2:     u16 align(1) = 0,
	esp2:   u32 align(1) = 0,
	ss2:    u16 align(1) = 0,
	_3:     u16 align(1) = 0,
	cr3:    u32 align(1) = 0,
	eip:    u32 align(1) = 0,
	eflags: u32 align(1) = 0,
	eax:    u32 align(1) = 0,
	ecx:    u32 align(1) = 0,
	edx:    u32 align(1) = 0,
	ebx:    u32 align(1) = 0,
	esp:    u32 align(1) = 0,
	ebp:    u32 align(1) = 0,
	esi:    u32 align(1) = 0,
	edi:    u32 align(1) = 0,
	es:     u16 align(1) = 0,
	_4:     u16 align(1) = 0,
	cs:     u16 align(1) = 0,
	_5:     u16 align(1) = 0,
	ss:     u16 align(1) = 0,
	_6:     u16 align(1) = 0,
	ds:     u16 align(1) = 0,
	_7:     u16 align(1) = 0,
	fs:     u16 align(1) = 0,
	_8:     u16 align(1) = 0,
	gs:     u16 align(1) = 0,
	_9:     u16 align(1) = 0,
	ldtr:   u16 align(1) = 0,
	_10:    u16 align(1) = 0,
	_11:    u16 align(1) = 0,
	iopb:   u16 align(1) = @sizeOf( Tss ),
	ssp:    u32 align(1) = 0,
};

var table: [6]Entry = undefined;
var ptr: x86.TablePtr = undefined;
var tss: Tss = .{};

pub fn init() void {
	table[0].set( 0, 0, @bitCast( @as( u8, 0 ) ), @bitCast( @as( u4, 0 ) ) );
	table[1].set( 0, 0xfffff, Entry.Access.KERNEL_CODE, .{} );
	table[2].set( 0, 0xfffff, Entry.Access.KERNEL_DATA, .{} );
	table[3].set( 0, 0xfffff, Entry.Access.USER_CODE, .{} );
	table[4].set( 0, 0xfffff, Entry.Access.USER_DATA, .{} );
	table[5].set( @intFromPtr( &tss ), @sizeOf( Tss ), Entry.Access.TSS, @bitCast( @as( u4, 0 ) ) );

	tss = std.mem.zeroes( Tss );
	tss.ss0 = 2 << 3;
	tss.iopb = @sizeOf( Tss );

	ptr = x86.TablePtr.init( Entry, 6, &table );
	asm volatile ( "lgdt (%%eax)" :: [ptr] "{eax}" ( @intFromPtr( &ptr ) - 0xc000_0000 ) );
	asm volatile ( "ltr %%ax" :: [id] "{ax}" ( 5 * 8 ) );

	asm volatile (
		\\ movw %%ax, %%ds
		\\ movw %%ax, %%es
		\\ movw %%ax, %%fs
		\\ movw %%ax, %%gs
		\\ movw %%ax, %%ss
		:: [offset] "{ax}" ( 0x10 )
	);

	asm volatile (
		\\ jmp $0x08, $gdt_flush
		\\ gdt_flush:
	);
}
