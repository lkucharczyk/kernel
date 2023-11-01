const std = @import( "std" );
const root = @import( "root" );
const ethernet = @import( "../net/ethernet.zig" );
const irq = @import( "../irq.zig" );
const net = @import( "../net.zig" );
const pci = @import( "../pci.zig" );
const x86 = @import( "../x86.zig" );
const RingBuffer = @import( "../util/ringBuffer.zig" ).RingBuffer;
const RingBufferExt = @import( "../util/ringBuffer.zig" ).RingBufferExt;

var devices: std.ArrayList( Rtl8139 ) = undefined;

const RegisterOffset = struct {
	/// u32
	const TxStatus = [4]u8 { 0x10, 0x14, 0x18, 0x1c };
	/// u32
	const TxAddress = [4]u8 { 0x20, 0x24, 0x28, 0x2c };
	/// u32
	const RxBufferAddress = 0x30;
	/// u8
	const Command = 0x37;
	/// u16
	const CurrentAddressPacketRead = 0x38;
	/// u16
	const CurrentBufferAddress = 0x3a;
	/// u16
	const InterruptMask = 0x3c;
	/// u16
	const InterruptStatus = 0x3e;
	/// u32
	const TxConfig = 0x40;
	/// u32
	const RxConfig = 0x44;
	/// u8
	const Config1 = 0x52;
	/// u8
	const MediaStatus = 0x58;
};

const TxStatus = packed struct(u32) {
	length: u13 = 0,
	own: bool = false,
	/// readonly
	fifoUnderrun: bool = false,
	/// readonly
	txOk: bool = false,
	earlyTxThreashold: u6 = 0,
	_: u2 = 0,
	/// readonly
	collisionCount: u4 = 0,
	/// readonly
	cdHeartbeat: bool = false,
	/// readonly
	outOfWindowCollison: bool = false,
	/// readonly
	txAbort: bool = false,
	/// readonly
	carrierLost: bool = false
};

const Command = packed struct(u8) {
	/// readonly
	bufferEmpty: bool = false,
	_0: u1 = 0,
	txEnable: bool = false,
	rxEnable: bool = false,
	reset: bool = false,
	_1: u3 = 0
};

const InterruptMask = packed struct(u16) {
	rxOk: bool = false,
	rxError: bool = false,
	txOk: bool = false,
	txError: bool = false,
	rxBufferOverflow: bool = false,
	linkChange: bool = false,
	rxFifoOverflow: bool = false,
	_: u6 = 0,
	cableLenChange: bool = false,
	timeout: bool = false,
	systemError: bool = false
};

const InterruptStatus = packed struct(u16) {
	rxOk: bool = false,
	rxError: bool = false,
	txOk: bool = false,
	txError: bool = false,
	rxBufferOverflow: bool = false,
	linkChange: bool = false,
	rxFifoOverflow: bool = false,
	_: u6 = 0,
	cableLenChange: bool = false,
	timeout: bool = false,
	systemError: bool = false,

	pub fn isEmpty( self: InterruptStatus ) bool {
		return ( @as( u16, @bitCast( self ) ) & 0b11100000_01111111 ) == 0;
	}

	pub fn format( self: InterruptStatus, _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		try std.fmt.format( writer, "{s}{{ ", .{ @typeName( InterruptStatus ) } );

		const ti = @typeInfo( InterruptStatus ).Struct;
		inline for ( ti.fields ) |field| {
			if ( field.type == bool and @field( self, field.name ) ) {
				try std.fmt.format( writer, "{s} ", .{ field.name } );
			}
		}

		try std.fmt.format( writer, "}}", .{} );
	}
};

const TxConfig = packed struct(u32) {
	clearAbort: bool = false,
	_0: u3 = 0,
	/// real retry count: 16 + ( 16 * retryCount )
	retryCount: u4 = 0,
	maxDmaBurst: u3 = 0,
	_1: u5 = 0,
	autoCrc: bool = false,
	/// 00 - disabled
	/// 11 - enabled
	loopback: u2 = 0,
	_2: u3 = 0,
	/// readonly
	hwVersionIdB: u2 = 0,
	interframeGap: u2 = 0,
	hwVersionIdA: u5 = 0,
	_3: u1 = 0
};

const RxConfig = packed struct(u32) {
	acceptAll: bool = false,
	acceptDirect: bool = false,
	acceptMulticast: bool = false,
	acceptBroadcast: bool = false,
	acceptRunt: bool = false,
	acceptError: bool = false,
	_0: u1 = 0,
	wrap: bool = false,
	maxDmaBurst: u3 = 0,
	bufferLen: u2 = 0,
	fifoThreshold: u3 = 0,
	rer8: bool = false,
	mulEarlyInt: bool = false,
	_1: u6 = 0,
	earlyThreshold: u4 = 0,
	_2: u4 = 0
};

const MediaStatus = packed struct(u8) {
	// readonly
	rxPause: bool = false,
	// readonly
	txPause: bool = false,
	// readonly
	linkFail: bool = false,
	// readonly
	slowSpeed: bool = false,
	// readonly
	auxPower: bool = false,
	_: u1 = 0,
	rxFlowControl: bool = false,
	txFlowControl: bool = false,
};

const DataHeader = packed struct(u32) {
	rxOk: bool,
	frameAlignError: bool,
	crcError: bool,
	isLong: bool,
	isRunt: bool,
	invalidSymbolError: bool,
	_: u7,
	matchBroadcast: bool,
	matchPhysicalAddr: bool,
	matchMulticast: bool,
	len: u16,

	pub fn isValid( self: DataHeader ) bool {
		return self.rxOk
			and !(
				self.isRunt
				or self.isLong
				or self.crcError
				or self.frameAlignError
			)
			and self.len >= ethernet.Frame.MIN_LENGTH
			and self.len <= ethernet.Frame.MAX_LENGTH;
	}

	pub fn format( self: DataHeader, _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		try std.fmt.format( writer, "{s}{{ .len = {}, flags = [ ", .{ @typeName( InterruptStatus ), self.len } );

		const ti = @typeInfo( DataHeader ).Struct;
		inline for ( ti.fields ) |field| {
			if ( field.type == bool and @field( self, field.name ) ) {
				try std.fmt.format( writer, "{s} ", .{ field.name } );
			}
		}

		try std.fmt.format( writer, "] }}", .{} );
	}
};

const Rtl8139 = struct {
	device: *pci.Device,
	interface: *net.Interface,

	ioAddr: u16,
	macAddr: ethernet.Address,

	txBuffer: RingBuffer( ethernet.FrameStatic, 4 ),
	rxBuffer: RingBufferExt( 8 * 1024, 16 ),

	fn init( self: *Rtl8139, dev: *pci.Device ) void {
		self.device = dev;
		self.ioAddr = @truncate( dev.headerExt.ext0.barAddr0 & ~@as( u16, 0x3 ) );
		self.txBuffer = .{};
		self.rxBuffer = .{};

		var mac: [6]u8 = undefined;
		for ( 0..6 ) |i| {
			mac[i] = self.in( u8, @intCast( i ) );
		}
		self.macAddr = ethernet.Address.init( mac );

		self.start();

		root.log.printUnsafe( "rtl8139: {}@{x:0>4} {}\n", .{ self.device.address, self.ioAddr, self.macAddr } );

		self.interface = net.createInterface( .{
			.context = self,
			.hwAddr = self.macAddr,
			.vtable = .{ .send = @ptrCast( &send ) }
		} );
	}

	fn start( self: *Rtl8139 ) void {
		self.device.header.command.busMaster = true;
		self.device.out( u16, 4, @bitCast( self.device.header.command ) );
		self.device.header.command = @bitCast( @as( u16, @truncate( self.device.in( u32, 4 ) ) ) );

		// Power on
		self.out( u8, RegisterOffset.Config1, 0 );

		self.outT( Command { .reset = true } );
		while ( self.inT( Command ).reset ) {
		}

		self.outT( TxConfig { .autoCrc = true } );

		self.out( u32, RegisterOffset.RxBufferAddress, @intFromPtr( &self.rxBuffer.data ) - 0xc000_0000 );
		self.outT( RxConfig {
			.acceptAll = true,
			.acceptDirect = true,
			.acceptMulticast = true,
			.acceptBroadcast = true,
		} );

		self.outT( MediaStatus { .rxFlowControl = true, .txFlowControl = true } );
		self.outT( InterruptMask {
			.rxOk = true,
			.txOk = false,
			.rxBufferOverflow = true,
			.rxFifoOverflow = true
		} );
		self.outT( Command { .rxEnable = true, .txEnable = true } );
	}

	fn send( self: *Rtl8139, frame: ethernet.Frame ) void {
		var i = self.txBuffer.posw;
		if ( self.txBuffer.pushUndefined() ) |bufFrame| {
			frame.copyTo( bufFrame );

			bufFrame.header.src = self.macAddr;

			x86.disableInterrupts();
			self.out( u32, RegisterOffset.TxAddress[i], @intFromPtr( bufFrame ) - 0xc000_0000 );
			self.out( TxStatus, RegisterOffset.TxStatus[i], .{
				.length = @truncate( bufFrame.len ),
				.own = false,
				.txOk = true
			} );

			while ( !self.in( TxStatus, RegisterOffset.TxStatus[i] ).txOk ) {
			}

			_ = self.txBuffer.pop();
			self.outT( InterruptStatus { .txOk = true } );
			x86.enableInterrupts();
		} else {
			@panic( "rtl8139 tx buffer full" );
		}
	}

	fn irqHandler( self: *Rtl8139 ) void {
		var status = self.inT( InterruptStatus );
		var i: usize = 8;

		while ( !status.isEmpty() and i > 0 ) : ( status = self.inT( InterruptStatus ) ) {
			self.outT( status );

			if ( status.rxBufferOverflow ) {
				self.rxBuffer.pos = ( self.in( u16, RegisterOffset.CurrentBufferAddress ) % 8192 );
				self.out( u16, RegisterOffset.CurrentAddressPacketRead, @truncate( self.rxBuffer.pos -% 0x10 ) );
				self.outT( InterruptStatus { .rxOk = true } );
			}

			while ( status.rxOk and !self.inT( Command ).bufferEmpty ) {
				var dataHeader = self.rxBuffer.read( DataHeader );
				if ( dataHeader.isValid() ) {
					if ( self.interface.recv() ) |frame| {
						frame.header = self.rxBuffer.read( ethernet.Header );
						var mbuf: ?[]u8 = self.interface.allocator.alloc( u8, dataHeader.len - @sizeOf( ethernet.Header ) - 4 ) catch null;

						if ( mbuf ) |buf| {
							frame.body = ethernet.Body.init( buf );

							self.rxBuffer.readBytes( buf );
							self.rxBuffer.seek( 4 + 3 );
							self.rxBuffer.pos &= ~@as( u32, 3 );
						} else {
							frame.body = ethernet.Body.init( "" );
							self.rxBuffer.seek( dataHeader.len - @sizeOf( ethernet.Header ) + 3 );
							self.rxBuffer.pos &= ~@as( u32, 3 );
							root.log.printUnsafe( "Driver dropped frame!\n", .{} );
						}
					} else {
						self.rxBuffer.seek( dataHeader.len - @sizeOf( ethernet.Header ) + 3 );
						self.rxBuffer.pos &= ~@as( u32, 3 );
					}

					self.out( u16, RegisterOffset.CurrentAddressPacketRead, @truncate( self.rxBuffer.pos -% 0x10 ) );
				} else {
					self.rxBuffer.seek( -@sizeOf( DataHeader ) );
					break;
				}
			}

			i -= 1;
		}
	}

	fn match( dev: *const pci.Device ) bool {
		return dev.header.deviceId.vendorId == 0x10ec
			and dev.header.deviceId.deviceId == 0x8139;
	}

	inline fn in( self: Rtl8139, comptime T: type, offset: u8 ) T {
		return x86.in( T, self.ioAddr + offset );
	}

	inline fn out( self: Rtl8139, comptime T: type, offset: u8, data: T ) void {
		return x86.out( T, self.ioAddr + offset, data );
	}

	inline fn registerOffset( comptime T: type ) u16 {
		return   if ( T == Command         ) ( RegisterOffset.Command         )
			else if ( T == InterruptMask   ) ( RegisterOffset.InterruptMask   )
			else if ( T == InterruptStatus ) ( RegisterOffset.InterruptStatus )
			else if ( T == TxConfig        ) ( RegisterOffset.TxConfig        )
			else if ( T == RxConfig        ) ( RegisterOffset.RxConfig        )
			else if ( T == MediaStatus     ) ( RegisterOffset.MediaStatus     )
			else @compileError( "invalid type" );
	}

	inline fn inT( self: Rtl8139, comptime T: type ) T {
		return x86.in( T, self.ioAddr + Rtl8139.registerOffset( T ) );
	}

	inline fn outT( self: Rtl8139, data: anytype ) void {
		return x86.out( @TypeOf( data ), self.ioAddr + Rtl8139.registerOffset( @TypeOf( data ) ), data );
	}
};

fn irqHandler( _: *x86.State ) void {
	for ( devices.items ) |*d| {
		d.irqHandler();
	}
}

pub fn init() std.mem.Allocator.Error!void {
	devices = std.ArrayList( Rtl8139 ).init( root.kheap );

	for ( pci.devices.items ) |*dev| {
		if ( Rtl8139.match( dev ) ) {
			irq.set( 32 + dev.headerExt.ext0.intLine, irqHandler );

			( try devices.addOne() ).init( dev );
		}
	}
}
