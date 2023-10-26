const gdt = @import( "./gdt.zig" );
const idt = @import( "./idt.zig" );
const irq = @import( "./irq.zig" );
const x86 = @import( "./x86.zig" );

export fn isrPanicWrapper() callconv(.Naked) noreturn {
	x86.saveState( true );
	asm volatile ( "call isrPanic" );
}

export fn irqHandlerWrapper() callconv(.Naked) noreturn {
	x86.saveState( true );
	asm volatile ( "call irqHandler" );
	x86.restoreState();
	asm volatile ( "iret" );
}

const Stub = fn() callconv(.Naked) void;
pub fn getStub( comptime int: u32, comptime panic: bool ) Stub {
	return struct {
		fn stub() callconv(.Naked) noreturn {
			x86.disableInterrupts();

			// Fill missing error code
			if (
				int != 8
				and !( int >= 10 and int <= 14 )
				and int != 17
				and int != 21
				and int != 29
				and int != 30
			) {
				asm volatile ( "pushl $0" );
			}

			asm volatile ( "pushl %[int]" :: [int] "n" ( int ) );

			if ( panic ) {
				asm volatile ( "jmp isrPanicWrapper" );
			} else {
				asm volatile ( "jmp irqHandlerWrapper" );
			}
		}
	}.stub;
}

pub fn init() void {
	// panic on exceptions
	inline for ( 0..32 ) |i| {
		const stub = getStub( i, true );
		idt.table[i].set( @intFromPtr( &stub ), gdt.Segment.KERNEL_CODE );
	}
}
