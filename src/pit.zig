const irq = @import( "./irq.zig" );
const x86 = @import( "./x86.zig" );

const MAX_FREQ = 1193182;

const Register = struct {
	const Counter0 = 0x40;
	const Counter1 = 0x41;
	const Counter2 = 0x42;
	const Control  = 0x43;
};

const Mode = enum(u3) {
	Interrupt  = 0b000,
	HwOneShot  = 0b001,
	RateGen    = 0b010,
	SquareWave = 0b011,
	SwStrobe   = 0b100,
	HwStrobe   = 0b101
	// RateGen    = 0b110,
	// SquareWave = 0b111
};

const Access = enum(u2) {
	Count     = 0,
	ReloadLsb = 1,
	ReloadMsb = 2,
	/// Reload value (first LSB, then MSB)
	Reload    = 3
};

const Setup = packed struct(u8) {
	bcd: bool = false,
	mode: Mode,
	access: Access,
	/// 0 | 1 | 2
	counter: u2
};

pub fn init( freq: u32 ) void {
	const reloadVal: u16 = @truncate( @divTrunc( MAX_FREQ + @divTrunc( freq, 2 ), freq ) );

	x86.out( Setup, Register.Control, .{
		.counter = 0,
		.access = .Reload,
		.mode = .SquareWave
	} );

	x86.out( u8, Register.Counter0, @truncate( reloadVal ) );
	x86.out( u8, Register.Counter0, @truncate( reloadVal >> 8 ) );
}
