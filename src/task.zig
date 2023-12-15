const std = @import( "std" );
const root = @import( "root" );
const elf = @import( "./elf.zig" );
const gdt = @import( "./gdt.zig" );
const irq = @import( "./irq.zig" );
const mem = @import( "./mem.zig" );
const vfs = @import( "./vfs.zig" );
const x86 = @import( "./x86.zig" );
const AnySeekableStream = @import( "./util/stream.zig" ).AnySeekableStream;

pub const Errno = @import( "./task/errno.zig" ).Errno;
pub const Error = @import( "./task/errno.zig" ).Error;
pub const MMap = @import( "./task/mmap.zig" ).MMap;

pub var kernelTask: *Task = undefined;
pub var currentTask: *Task = undefined;

const KS = 64 * 1024;

const FdWait = struct {
	ptr: *vfs.FileDescriptor,
	status: vfs.FileDescriptor.Status,

	pub fn ready( self: FdWait ) bool {
		return ( !self.status.read or self.ptr.status.read )
			and ( !self.status.write or self.ptr.status.write )
			and ( !self.status.other or self.ptr.status.other );
	}
};

pub const PollFd = extern struct {
	pub const Events = packed struct(u16) {
		read: bool = false,
		priority: bool = false,
		write: bool = false,
		err: bool = false,
		hangup: bool = false,
		noVal: bool = false,
		_: u10 = 0,

		pub fn any( self: Events ) bool {
			return @as( u16, @bitCast( self ) ) > 0;
		}
	};

	fd: u32,
	reqEvents: Events,
	retEvents: Events = .{},

	pub fn ready( self: *PollFd, task: *Task ) bool {
		var out: bool = false;
		self.retEvents = .{};

		if ( task.getFd( self.fd ) ) |fd| {
			inline for ( .{ "read", "write" } ) |f| {
				if ( @field( fd.status, f ) and @field( self.reqEvents, f ) ) {
					@field( self.retEvents, f ) = true;
					out = true;
				}
			}
		} else |_| {
			self.retEvents.noVal = true;
		}

		return out;
	}
};

pub const PollWait = struct {
	fd: []PollFd,

	pub fn ready( self: *PollWait, task: *Task ) bool {
		var out: bool = false;

		for ( self.fd ) |*fd| {
			if ( fd.ready( task ) ) {
				out = true;
			}
		}

		return out;
	}
};

const StatusWait = union(enum) {
	fd: FdWait,
	poll: PollWait,
	task: *Task,
	Manual,

	pub fn ready( self: *StatusWait, task: *Task ) bool {
		return switch ( self.* ) {
			.fd => |fd| fd.ready(),
			.poll => |*poll| poll.ready( task ),
			else => false
		};
	}

	pub fn format( self: StatusWait, _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		try switch ( self ) {
			.fd => |fd| std.fmt.format( writer, "fd:{s}", .{ fd.ptr.node.name } ),
			.poll => std.fmt.format( writer, "poll", .{} ),
			.task => |t| std.fmt.format( writer, "task:{s}", .{ t.id } ),
			.Manual => std.fmt.format( writer, "manual", .{} )
		};
	}
};

const Status = union(enum) {
	Kernel,
	Start,
	Wait: StatusWait,
	Active,
	Done
};

pub const Task = struct {
	id: u8,
	bin: ?[:0]const u8 = null,
	status: Status,
	kernelMode: bool,
	entrypoint: *const fn( argc: [*]usize ) callconv(.C) void,
	stackPtr: x86.StackPtr = undefined,
	kstack: []align(4096) usize = undefined,
	programBreak: usize = 0,
	stackBreak: usize = mem.ADDR_KMAIN_OFFSET - 4 * @sizeOf( usize ),
	mmap: MMap = undefined,
	fd: std.ArrayListUnmanaged( ?*vfs.FileDescriptor ) = undefined,
	tls: ?gdt.Entry = null,

	fn init( self: *Task, parent: *const Task, state: ?*const x86.State ) std.mem.Allocator.Error!void {
		self.kstack = try root.kheap.alignedAlloc( usize, 4096, KS / @sizeOf( usize ) );
		errdefer root.kheap.free( self.kstack );

		self.programBreak = parent.programBreak;
		self.stackBreak = parent.stackBreak;
		self.mmap = try parent.mmap.dupe( root.kheap );
		errdefer self.mmap.deinit();

		_ = try self.mmap.alloc( mem.ADDR_KMAIN_OFFSET - mem.PAGE_SIZE, mem.PAGE_SIZE );

		self.fd = try std.ArrayListUnmanaged( ?*vfs.FileDescriptor ).initCapacity( root.kheap, @max( 3, parent.fd.items.len ) );
		errdefer self.fd.deinit( root.kheap );
		for ( parent.fd.items ) |fd| {
			if ( fd ) |f| {
				self.fd.appendAssumeCapacity( try f.node.open() );
			} else {
				self.fd.appendAssumeCapacity( null );
			}
		}

		self.stackPtr = .{
			.ebp = @intFromPtr( &self.kstack[self.kstack.len - 1] ),
			.esp = @intFromPtr( &self.kstack[self.kstack.len - 9] )
		};

		var tmpState: x86.State = undefined;
		if ( state ) |s| {
			tmpState = s.*;
		} else {
			tmpState.eip = @intFromPtr( self.entrypoint );
			tmpState.uesp = self.stackBreak;
			tmpState.ebp = self.stackBreak;
		}

		tmpState.eax = 0;

		// data segment offset
		if ( self.kernelMode ) {
			self.pushToKstack( gdt.Segment.KERNEL_DATA );
		} else {
			self.pushToKstack( gdt.Segment.USER_DATA | 3 );
		}

		// user stack pointer
		self.pushToKstack( tmpState.uesp );

		// eflags; enable interrupts after iret
		self.pushToKstack(
			asm volatile (
				\\ pushf
				\\ popl %%eax
				\\ orl $0x200, %%eax
				: [_] "={eax}" (-> usize)
			)
		);

		// code segment offset
		if ( self.kernelMode ) {
			self.pushToKstack( gdt.Segment.KERNEL_CODE );
		} else {
			self.pushToKstack( gdt.Segment.USER_CODE | 3 );
		}

		// entrypoint
		self.pushToKstack( tmpState.eip );

		// pusha
		self.pushToKstack( tmpState.eax );
		self.pushToKstack( tmpState.ecx );
		self.pushToKstack( tmpState.edx );
		self.pushToKstack( tmpState.ebx );
		self.pushToKstack( tmpState.uesp );
		self.pushToKstack( tmpState.ebp );
		self.pushToKstack( tmpState.esi );
		self.pushToKstack( tmpState.edi );
	}

	fn deinit( self: *Task ) void {
		self.mmap.deinit();
		root.kheap.free( self.kstack );

		if ( self.bin ) |bin| {
			root.kheap.free( bin );
		}
	}

	pub fn map( self: *Task ) void {
		// root.log.printUnsafe( "task.map: {any}\n", .{ self.mmap.entries.items } );
		self.mmap.map();

		if ( self.tls ) |tls| {
			gdt.table[gdt.Segment.TLS >> 3] = tls;
		} else {
			gdt.table[gdt.Segment.TLS >> 3].unset();
		}
	}

	pub fn unmap( self: *Task ) void {
		self.mmap.unmap();
		gdt.table[gdt.Segment.TLS >> 3].unset();
	}

	fn enter( self: *Task ) void {
		gdt.tss.esp0 = @intFromPtr( self.kstack.ptr ) + KS - ( 9 * 4 );

		currentTask.unmap();
		self.map();

		currentTask.stackPtr = x86.StackPtr.get();
		currentTask = self;
		currentTask.stackPtr.set();

		if ( currentTask.status == .Start ) {
			currentTask.status = .Active;
			asm volatile (
				\\ popa
				\\ iret
			);
		}

		asm volatile ( "task_end:" );
	}

	pub fn park( self: *Task, waitOn: StatusWait ) void {
		// root.log.printUnsafe( "park:{} {}\n", .{ self.id, waitOn } );
		self.status = .{ .Wait = waitOn };
		if ( currentTask == self ) {
			asm volatile ( "int $0x20" );
		}
	}

	pub fn exit( self: *Task, code: u32 ) noreturn {
		x86.disableInterrupts();
		self.status = .Done;
		root.log.printUnsafe( "\nTask {} exited with code {}.\n", .{ self.id, code } );

		for ( 0..tasks.len ) |i| {
			if ( tasks[i] ) |*t| {
				if ( t.status == .Wait and t.status.Wait == .task and t.status.Wait.task == self ) {
					t.status = .Active;
				}
			}
		}

		self.unmap();
		currentTask = self;
		kernelTask.stackPtr.set();
		gdt.tss.esp0 = 0;
		currentTask = kernelTask;

		asm volatile ( "jmp task_end" );
		unreachable;
	}

	pub fn addFd( self: *Task, node: *vfs.Node ) error{ OutOfMemory }!isize {
		for ( self.fd.items, 0.. ) |*fd, i| {
			if ( fd.* == null ) {
				fd.* = try node.open();
				return @bitCast( i );
			}
		}

		( try self.fd.addOne( root.kheap ) ).* = try node.open();
		return @bitCast( self.fd.items.len - 1 );
	}

	pub fn getFd( self: *Task, fd: u32 ) error{ BadFileDescriptor }!*vfs.FileDescriptor {
		if ( fd < self.fd.items.len ) {
			if ( self.fd.items[fd] ) |out| {
				return out;
			}
		}

		return error.BadFileDescriptor;
	}

	pub fn fork( self: *Task, state: *const x86.State ) error{ OutOfMemory, ResourceUnavailable }!*Task {
		for ( 0..tasks.len ) |_| {
			tcc +%= 1;

			if ( tasks[tcc] == null ) {
				errdefer tasks[tcc] = null;

				// x86.disableInterrupts();
				tasks[tcc] = Task {
					.id = tcc,
					.status = .Start,
					.kernelMode = self.kernelMode,
					.entrypoint = self.entrypoint,
				};
				try tasks[tcc].?.init( self, state );
				// x86.enableInterrupts();

				return &( tasks[tcc].? );
			}
		}

		return Error.ResourceUnavailable;
	}

	pub fn loadElf( self: *Task, reader: std.io.AnyReader, seeker: AnySeekableStream, args: [2][]const [*:0]const u8 ) anyerror!void {
		var arena = std.heap.ArenaAllocator.init( root.kheap );
		const alloc = arena.allocator();
		defer arena.deinit();

		try seeker.seekTo( 0 );
		const curElf = try elf.read( reader, seeker );
		self.entrypoint = @ptrFromInt( curElf.header.e_entry );

		const sections = try curElf.readSectionTable( alloc );

		self.programBreak = 0;
		self.mmap.deinit();
		self.mmap = MMap.init( root.kheap );

		for ( sections ) |section| {
			if ( ( section.sh_flags & std.elf.SHF_ALLOC ) > 0 ) {
				const ptr = @as( [*]u8, @ptrFromInt( section.sh_addr ) )[0..section.sh_size];
				self.programBreak = std.mem.alignForward( usize, @max( self.programBreak, @intFromPtr( ptr.ptr + ptr.len ) ), 4096 );

				if ( try self.mmap.alloc( @intFromPtr( ptr.ptr ), ptr.len ) ) {
					self.mmap.map();
				}

				if ( section.sh_type == std.elf.SHT_NOBITS ) {
					@memset( ptr, 0 );
				} else if ( section.sh_type != std.elf.SHT_NULL ) {
					try seeker.seekTo( section.sh_offset );
					_ = try reader.readAll( ptr );
				}
			}
		}

		_ = try self.mmap.alloc( mem.ADDR_KMAIN_OFFSET - mem.PAGE_SIZE, mem.PAGE_SIZE );
		self.mmap.map();
		const ustack = @as( [*]usize, @ptrFromInt( mem.ADDR_KMAIN_OFFSET - mem.PAGE_SIZE ) )[0..( mem.PAGE_SIZE / @sizeOf( usize ) )];
		@memset( ustack, 0 );

		// auxv
		self.pushToUstack( 0 );
		self.pushToUstack( std.elf.AT_NULL );
		self.pushToUstack( 4096 );
		self.pushToUstack( std.elf.AT_PAGESZ );

		// env, argv
		const dataAddr = std.mem.alignForward( usize, self.programBreak, 4096 );
		const dataPtr: [*]u8 = @ptrFromInt( dataAddr );
		var dataOff: usize = 0;
		inline for ( .{ args[1], args[0] } ) |arg| {
			self.pushToUstack( 0 );
			for ( 1..( arg.len + 1 ) ) |i| {
				self.pushToUstack( dataAddr + dataOff );

				const len = std.mem.len( arg[arg.len - i] ) + 1;
				@memcpy( dataPtr[dataOff..], arg[arg.len - i][0..len] );
				dataOff += len;
			}
		}

		self.pushToUstack( args[0].len );
		self.programBreak = std.mem.alignForward( usize, dataAddr + dataOff, 4096 );

		self.mmap.unmap();
	}

	fn pushToKstack( self: *Task, val: usize ) void {
		const ptr: *usize = @ptrFromInt( self.stackPtr.esp - @sizeOf( usize ) );
		ptr.* = val;
		self.stackPtr.esp = @intFromPtr( ptr );
	}

	fn pushToUstack( self: *Task, val: usize ) void {
		const ptr: *usize = @ptrFromInt( self.stackBreak - @sizeOf( usize ) );
		ptr.* = val;
		self.stackBreak = @intFromPtr( ptr );
	}
};

var tasks: [16]?Task = undefined;
var tcc: u4 = 0;
var tcs: u4 = 0;

pub fn init() std.mem.Allocator.Error!void {
	tasks[0] = Task {
		.id = 0,
		.status = .Kernel,
		.kernelMode = true,
		.entrypoint = undefined,
		.fd = try std.ArrayListUnmanaged( ?*vfs.FileDescriptor ).initCapacity( root.kheap, 3 ),
		.mmap = MMap.init( root.kheap )
	};

	kernelTask = &tasks[0].?;
	currentTask = kernelTask;
	@memset( tasks[1..], null );

	if ( vfs.devNode.resolve( "com0" ) ) |com| {
		kernelTask.fd.appendAssumeCapacity( try com.open() );
		kernelTask.fd.appendAssumeCapacity( try com.open() );
		kernelTask.fd.appendAssumeCapacity( try com.open() );
	}
}

pub fn create( entrypoint: *const fn( argc: [*]usize ) callconv(.C) void, kernelMode: bool ) *Task {
	for ( 0..tasks.len ) |_| {
		tcc +%= 1;

		if ( tasks[tcc] == null ) {
			x86.disableInterrupts();
			tasks[tcc] = Task {
				.id = tcc,
				.status = .Start,
				.kernelMode = kernelMode,
				.entrypoint = entrypoint
			};
			tasks[tcc].?.init( kernelTask, null ) catch unreachable;
			x86.enableInterrupts();

			return &( tasks[tcc].? );
		}
	}

	@panic( "Can't create a new task" );
}

pub fn createElf( reader: std.io.AnyReader, seeker: AnySeekableStream, args: [2][]const [*:0]const u8 ) !*Task {
	const newTask = create( @ptrFromInt( 0xdeaddead ), false );
	try newTask.loadElf( reader, seeker, args );
	newTask.kstack[newTask.kstack.len - 14] = @truncate( @intFromPtr( newTask.entrypoint ) );
	newTask.kstack[newTask.kstack.len - 11] = newTask.stackBreak;
	return newTask;
}

fn countTasks( includeWait: bool ) usize {
	var out: usize = 0;

	for ( 1..tasks.len ) |i| {
		if ( tasks[i] ) |*t| {
			if ( t.status != .Kernel and t.status != .Done and ( includeWait or t.status != .Wait ) ) {
				out += 1;
			} else if ( t.status == .Done ) {
				t.deinit();
				tasks[tcs] = null;
			}
		}
	}

	return out;
}

pub fn schedule() void {
	x86.disableInterrupts();
	irq.set( irq.Interrupt.Pit, scheduler );

	while ( true ) {
		currentTask = kernelTask;
		// ticks = std.math.maxInt( @TypeOf( ticks ) );
		asm volatile ( "int %[irq]" :: [irq] "n" ( irq.Interrupt.Pit ) );

		// root.log.printUnsafe( "S ", .{} );

		if ( countTasks( true ) == 0 ) {
			break;
		}
	}

	root.log.printUnsafe( "\nAll tasks completed.\n", .{} );
	irq.unset( irq.Interrupt.Pit );
	x86.enableInterrupts();
}

// var ticks: u4 = std.math.maxInt( u4 );
fn scheduler( _: *x86.State ) void {
	// if ( currentTask.status != .Active ) {
	// 	ticks = std.math.maxInt( @TypeOf( ticks ) );
	// }

	// ticks +%= 1;
	// if ( ticks > 0 ) {
	// 	return;
	// }

	// root.log.printUnsafe( "s ", .{} );
	while ( true ) {
		for ( 0..tasks.len ) |_| {
			tcs +%= 1;

			if ( tasks[tcs] ) |*t| {
				if ( t.status == .Start or t.status == .Active ) {
					// root.log.printUnsafe( "sched:{}\n", .{ t.id } );
					if ( currentTask != t ) {
						t.enter();
					}

					return;
				} else if ( t.status == .Wait ) {
					if ( t.status.Wait.ready( t ) ) {
						t.status = .Active;
						// root.log.printUnsafe( "unpark:{}\n", .{ t.id } );
					}
				} else if ( t.status == .Done ) {
					t.deinit();
					tasks[tcs] = null;
				}
			}
		}

		if ( countTasks( true ) == 0 ) {
			return;
		} else if ( countTasks( false ) == 0 ) {
			irq.mask( irq.Interrupt.Pit );
			// root.log.printUnsafe( "hlt\n", .{} );
			x86.enableInterrupts();
			asm volatile ( "hlt" );
			x86.disableInterrupts();
			irq.unmask( irq.Interrupt.Pit );
		}
	}
}
