const std = @import( "std" );
const root = @import( "root" );
const gdt = @import( "./gdt.zig" );
const x86 = @import( "./x86.zig" );
const Stream = @import( "./util/stream.zig" ).Stream;

const RegisterOffset = struct {
	pub const Data            = 0;
	pub const InterruptEnable = 1;
	/// Available when DLAB=1
	pub const DivisorLow      = 0;
	/// Available when DLAB=1
	pub const DivisorHigh     = 1;
	pub const InerruptStatus  = 2;
	pub const LineControl     = 3;
	pub const ModemControl    = 4;
	pub const LineStatus      = 5;
	pub const ModemStatus     = 6;
	pub const Scratch         = 7;
};

const PortAddress = enum(u16) {
	COM1 = 0x03f8,
	COM2 = 0x02f8,
	COM3 = 0x03e8,
	COM4 = 0x02e8,
	COM5 = 0x05f8,
	COM6 = 0x04f8,
	COM7 = 0x05e8,
	COM8 = 0x04e8
};

const Baud = enum(u16) {
	b115200 = 1,
	b57600  = 2,
	b38400  = 3,
	b19200  = 6,
	b9600   = 12,
	b300    = 384
};

const Mode = packed struct(u8) {
	dataBits: enum(u2) {
		b5 = 0,
		b6 = 1,
		b7 = 2,
		b8 = 3
	},
	// false - 1 stop bit
	// true  - 2 stop bits
	stopBits: bool,
	parity: enum(u3) {
		None  = 0b000,
		Odd   = 0b001,
		Even  = 0b011,
		/// Always 1
		Mark  = 0b101,
		/// Always 0
		Space = 0b111
	},
	_: u2 = 0
};

const Interrupts = packed struct(u8) {
	dataAvailable: bool = false,
	transmitterEmpty: bool = false,
	onError: bool = false,
	statusChange: bool = false,
	_: u4 = 0
};

const LineStatus = packed struct(u8) {
	dataReady: bool,
	overrunError: bool,
	parityError: bool,
	framingError: bool,
	breakIndicator: bool,
	txHoldEmpty: bool,
	txEmpty: bool,
	impendingError: bool,

	fn hasError( self: LineStatus ) bool {
		return ( @as( u8, @bitCast( self ) ) & 0b10001110 ) > 0;
	}
};

pub var ports: [8]?SerialPort = .{ null } ** 8;

pub const SerialPort = struct {
	address: u16,

	pub fn init( address: u16 ) ?SerialPort {
		const com = SerialPort { .address = address };

		com.setInterrupts( .{} );
		com.setMode( .b9600, .{
			.dataBits = .b8,
			.stopBits = false,
			.parity = .None
		} );

		if ( com.runSelfTest() ) {
			gdt.setPort( com.address + RegisterOffset.Data, true );
			gdt.setPort( com.address + RegisterOffset.LineStatus, true );
			return com;
		}

		return null;
	}

	inline fn in( self: SerialPort, comptime T: type, offset: u16 ) T {
		return x86.in( T, self.address + offset );
	}

	inline fn out( self: SerialPort, comptime T: type, offset: u16, val: T ) void {
		return x86.out( T, self.address + offset, val );
	}

	fn setMode( self: SerialPort, divisor: Baud, mode: Mode ) void {
		const div: u16 = @intFromEnum( divisor );
		self.out( u8, RegisterOffset.LineControl , 0x80 );
		self.out( u8, RegisterOffset.DivisorLow  , @truncate( div ) );
		self.out( u8, RegisterOffset.DivisorHigh , @truncate( div >> 8 ) );
		self.out( u8, RegisterOffset.LineControl , @bitCast( mode ) );
		self.out( u8, RegisterOffset.ModemControl, 0x0f );
	}

	fn setInterrupts( self: SerialPort, int: Interrupts ) void {
		self.out( u8, RegisterOffset.InterruptEnable, @bitCast( int ) );
	}

	fn runSelfTest( self: SerialPort ) bool {
		// enable loopback
		self.out( u8, RegisterOffset.ModemControl, 0x1f );

		inline for ( .{ 0x42, 0x24, 0xaf, 0xeb } ) |b| {
			self.out( u8, RegisterOffset.Data, b );
			if ( self.in( u8, RegisterOffset.Data ) != b ) {
				self.out( u8, RegisterOffset.ModemControl, 0x0f );
				return false;
			}
		}

		self.out( u8, RegisterOffset.ModemControl, 0x0f );
		return true;
	}

	fn getLineStatus( self: SerialPort ) LineStatus {
		const res = self.in( LineStatus, RegisterOffset.LineStatus );

		if ( res.hasError() ) {
			root.log.printUnsafe( "COM error detected: {}\n", .{ res } );
		}

		return res;
	}

	pub fn read( self: SerialPort, buf: []u8 ) usize {
		// self.setInterrupts( .{ .dataAvailable = true } );

		for ( 0..buf.len ) |i| {
			while ( !self.getLineStatus().dataReady ) {
				asm volatile ( "hlt" );
			}

			buf[i] = self.in( u8, RegisterOffset.Data );
			if ( buf[i] == '\r' ) {
				buf[i] = '\n';
			}
		}

		// self.setInterrupts( .{} );
		return buf.len;
	}

	pub fn write( self: SerialPort, buf: []const u8 ) usize {
		// self.setInterrupts( .{ .transmitterEmpty = true } );

		for ( buf ) |c| {
			if ( c == 0 ) {
				break;
			}

			while ( !self.getLineStatus().txHoldEmpty ) {
				asm volatile ( "hlt" );
			}

			if ( c == '\n' ) {
				self.out( u8, RegisterOffset.Data, '\r' );
				for ( 0..100 ) |_| {
					asm volatile ( "nop" );
				}
				while ( !self.getLineStatus().txHoldEmpty ) {
					asm volatile ( "hlt" );
				}
			}

			for ( 0..100 ) |_| {
				asm volatile ( "nop" );
			}

			self.out( u8, RegisterOffset.Data, c );
		}

		// self.setInterrupts( .{} );
		return buf.len;
	}

	pub fn print( self: SerialPort, comptime fmt: []const u8, args: anytype ) void {
		return std.fmt.format( self.writer(), fmt, args ) catch unreachable;
	}

	pub fn reader( self: SerialPort ) std.io.Reader( SerialPort, error{}, streamRead ) {
		return .{ .context = self };
	}

	pub fn writer( self: SerialPort ) std.io.Writer( SerialPort, error{}, streamWrite ) {
		return .{ .context = self };
	}

	pub fn streamRead( self: SerialPort, buf: []u8 ) error{}!usize {
		return self.read( buf );
	}

	pub fn streamWrite( self: SerialPort, buf: []const u8 ) error{}!usize {
		return self.write( buf );
	}

	pub fn stream( self: *SerialPort ) Stream {
		return .{
			.context = self,
			.vtable = .{
				.read = @ptrCast( &streamRead ),
				.write = @ptrCast( &streamWrite )
			}
		};
	}
};

pub fn init() void {
	const adresses = @typeInfo( PortAddress );
	inline for ( adresses.Enum.fields, 0.. ) |f, i| {
		ports[i] = SerialPort.init( f.value );
	}
}
