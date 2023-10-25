const x86 = @import( "./x86.zig" );

pub const Register = struct {
	pub const ControlSelect   = 0x03d4;
	pub const ControlData     = 0x03d5;
	pub const MiscWrite       = 0x03c2;
	pub const MiscRead        = 0x03cc;
	pub const SequencerSelect = 0x03c4;
	pub const SequencerData   = 0x03c5;
};

pub const ControlRegister = struct {
	pub const HorizontalTotal        = 0x00;
	pub const HorizontalDisplayEnd   = 0x01;
	pub const HorizontalBlankStart   = 0x02;
	pub const HorizontalBlankEnd     = 0x03;
	pub const HorizontalRetraceStart = 0x04;
	pub const HorizontalRetraceEnd   = 0x05;
	pub const VerticalTotal          = 0x06;
	pub const Overflow               = 0x07;
	pub const PresetRowScan          = 0x08;
	pub const MaximumScanLine        = 0x09;
	pub const CursorStart            = 0x0a;
	pub const CursorEnd              = 0x0b;
	pub const CursorLocHigh          = 0x0e;
	pub const CursorLocLow           = 0x0f;
	pub const VerticalRetraceStart   = 0x10;
	pub const VerticalRetraceEnd     = 0x11;
	pub const VerticalDisplayEnd     = 0x12;
	pub const Offset                 = 0x13;
	pub const UnderlineLocation      = 0x14;
	pub const VerticalBlankStart     = 0x15;
	pub const VerticalBlankEnd       = 0x16;
	pub const CrtcMode               = 0x17;
	pub const LineCompare            = 0x18;
};

pub const SequencerRegister = struct {
	pub const Reset        = 0x00;
	pub const ClockingMode = 0x01;
	pub const MapMask      = 0x02;
	pub const CharacterMap = 0x03;
	pub const MemoryMode   = 0x04;
};

pub fn setControlReg( reg: u8, val: u8 ) void {
	x86.out( u8, Register.ControlSelect, reg );
	x86.out( u8, Register.ControlData, val );
}
