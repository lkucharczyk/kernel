const std = @import( "std" );
const root = @import( "root" );
const x86 = @import( "./x86.zig" );
const gdt = @import( "./gdt.zig" );
const idt = @import( "./idt.zig" );
const isr = @import( "./isr.zig" );

pub const Interrupt = struct {
	pub const Pit      = 0x20;
	pub const Keyboard = 0x21;
	pub const Com2     = 0x22;
	pub const Com1     = 0x23;
	pub const Syscall  = 0x80;
};

pub const Register = struct {
	pub const Pic1Command = 0x20;
	pub const Pic1Data    = 0x21;
	pub const Pic2Command = 0xa0;
	pub const Pic2Data    = 0xa1;
};

pub const Command = struct {
	pub const Init           = 0x11;
	pub const EndOfInterrupt = 0x20;
};

const IrqHandler = *const fn( *x86.State ) void;
var handlers: [256 - 32]?IrqHandler = .{ null } ** ( 256 - 32 );

pub fn init() void {
	x86.out( u8, Register.Pic1Command, Command.Init );
	x86.out( u8, Register.Pic2Command, Command.Init );
	x86.out( u8, Register.Pic1Data, 0x20 ); // remap irq 0-7 to 32+
	x86.out( u8, Register.Pic2Data, 0x28 ); // remap irq 8+  to 40+
	x86.out( u8, Register.Pic1Data, 0x04 );
	x86.out( u8, Register.Pic2Data, 0x02 );
	x86.out( u8, Register.Pic1Data, 0x01 );
	x86.out( u8, Register.Pic2Data, 0x01 );
	x86.out( u8, Register.Pic1Data, 0x00 );
	x86.out( u8, Register.Pic2Data, 0x00 );

	inline for ( 32..( handlers.len + 32 ) ) |i| {
		const stub = isr.getStub( i, false );
		idt.table[i].set( @intFromPtr( &stub ), gdt.Segment.KERNEL_CODE );
	}
}

pub fn set( irq: u8, handler: IrqHandler ) void {
	if ( handlers[irq - 32] != null ) {
		@panic( "IRQ already set" );
	}

	handlers[irq - 32] = handler;
}

pub fn unset( irq: u8 ) void {
	handlers[irq - 32] = null;
}

export fn irqHandler( state: *x86.State ) void {
	// root.log.printUnsafe( "irq: {}:{}\n", .{ state.intNum, state.errNum } );

	if ( state.intNum >= 32 ) {
		if ( handlers[state.intNum - 32] ) |handler| {
			handler( state );
		}

		if ( state.intNum >= 40 ) {
			x86.out( u8, Register.Pic2Command, Command.EndOfInterrupt );
		}

		x86.out( u8, Register.Pic1Command, Command.EndOfInterrupt );
	}
}
