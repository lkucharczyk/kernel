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

	pub fn addFd( self: *Task, ptr: *vfs.FileDescriptor ) error{ OutOfMemory }!u32 {
		for ( self.fd.items, 0.. ) |*fd, i| {
			if ( fd.* == null ) {
				fd.* = ptr;
				return @bitCast( i );
			}
		}

		( try self.fd.addOne( root.kheap ) ).* = ptr;
		return self.fd.items.len - 1;
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

		const segments = try curElf.readProgramTable( alloc );

		self.programBreak = 0;
		self.mmap.deinit();
		self.mmap = MMap.init( root.kheap );

		var offset: usize = 0;
		if ( curElf.header.e_type == .DYN ) {
			offset = 0xa000_0000;
		}

		for ( segments ) |segment| {
			if ( segment.p_memsz > 0 and segment.p_type == std.elf.PT_LOAD ) {
				const ptr = @as( [*]allowzero u8, @ptrFromInt( segment.p_vaddr + offset ) )[0..segment.p_filesz];
				self.programBreak = std.mem.alignForward( usize, @max( self.programBreak, @intFromPtr( ptr.ptr + segment.p_memsz ) ), 4096 );

				if ( try self.mmap.alloc( @intFromPtr( ptr.ptr ), ptr.len ) ) {
					self.mmap.map();
				}

				try seeker.seekTo( segment.p_offset );
				_ = try reader.readAll( _: {
					@setRuntimeSafety( false );
					break :_ @ptrCast( ptr );
				} );

				if ( segment.p_filesz < segment.p_memsz ) {
					@memset( ptr.ptr[segment.p_filesz..segment.p_memsz], 0 );
				}
			} else if ( segment.p_memsz > 0 and segment.p_type == std.elf.PT_INTERP ) {
				try seeker.seekTo( segment.p_offset );
				const interp = try alloc.allocSentinel( u8, segment.p_filesz, 0 );
				_ = try reader.readAll( interp );

				const interpNode = vfs.rootNode.resolveDeep( interp[1..( std.mem.indexOfScalar( u8, interp, 0 ) orelse interp.len )] ) orelse return error.MissingFile;
				const interpFd = try interpNode.open();
				defer interpFd.close();

				const interpArgs = if ( self.bin != null and !std.mem.eql( u8, std.mem.sliceTo( args[0][0], 0 ), self.bin.? ) ) _: {
					const interpArgs = try alloc.alloc( [*:0]const u8, args[0].len + 3 );
					interpArgs[0] = interp;
					interpArgs[1] = "--argv0";
					interpArgs[2] = args[0][0];
					interpArgs[3] = self.bin orelse args[0][0];
					@memcpy( interpArgs[4..], args[0][1..] );
					break :_ interpArgs;
				} else _: {
					const interpArgs = try alloc.alloc( [*:0]const u8, args[0].len + 1 );
					interpArgs[0] = interp;
					@memcpy( interpArgs[1..], args[0] );
					break :_ interpArgs;
				};

				try self.loadElf( interpFd.reader(), interpFd.seekableStream(), .{ interpArgs, args[1] } );
				return;
			}
		}

		self.entrypoint = @ptrFromInt( curElf.header.e_entry + offset );
		self.stackBreak = std.mem.alignBackward( usize, mem.ADDR_KMAIN_OFFSET - 1, 64 );

		_ = try self.mmap.alloc( mem.ADDR_KMAIN_OFFSET - mem.PAGE_SIZE, mem.PAGE_SIZE );
		self.mmap.map();
		const ustack = @as( [*]usize, @ptrFromInt( mem.ADDR_KMAIN_OFFSET - mem.PAGE_SIZE ) )[0..( mem.PAGE_SIZE / @sizeOf( usize ) )];
		@memset( ustack, 0 );

		// env, argv - data
		const argsPtr = try alloc.alloc( usize, args[0].len + args[1].len + 2 );
		{
			var i: usize = 0;
			inline for ( .{ args[0], args[1] } ) |arg| {
				for ( arg ) |val| {
					const len = std.mem.len( val ) + 1;
					self.pushBytesToUstack( val[0..len] );
					argsPtr[i] = self.stackBreak;
					i += 1;
				}

				argsPtr[i] = 0;
				i += 1;
			}
		}

		// auxv
		self.pushSliceToUstack( &.{
			std.elf.AT_PAGESZ, mem.PAGE_SIZE,
			std.elf.AT_NULL  , 0
		} );

		if ( curElf.header.e_type == .DYN ) {
			self.pushSliceToUstack( &.{
				std.elf.AT_BASE , offset,
				std.elf.AT_PHDR , curElf.header.e_phoff + offset,
				std.elf.AT_PHENT, curElf.header.e_phentsize + offset,
				std.elf.AT_PHNUM, curElf.header.e_phnum + offset
			} );
		}

		self.pushToUstack( @intFromPtr( self.entrypoint ) );
		self.pushToUstack( std.elf.AT_ENTRY );

		// env, argv - pointers
		self.pushSliceToUstack( argsPtr );
		self.pushToUstack( args[0].len );

		if ( curElf.header.e_type == .DYN ) {
			self.programBreak = mem.PAGE_SIZE;
		}

		self.mmap.unmap();
	}

	fn pushToKstack( self: *Task, val: usize ) void {
		self.stackPtr.esp -= @sizeOf( usize );
		@as( *usize, @ptrFromInt( self.stackPtr.esp ) ).* = val;
	}

	fn pushToUstack( self: *Task, val: usize ) void {
		self.stackBreak -= @sizeOf( usize );
		@as( *usize, @ptrFromInt( self.stackBreak ) ).* = val;
	}

	fn pushBytesToUstack( self: *Task, slice: []const u8 ) void {
		const len = std.mem.alignForward( usize, slice.len, @sizeOf( usize ) );
		self.stackBreak -= len * @sizeOf( u8 );

		const ptr: []u8 = @as( [*]u8, @ptrFromInt( self.stackBreak ) )[0..len];
		@memcpy( ptr[0..slice.len], slice );
		if ( len > slice.len ) {
			@memset( ptr[slice.len..len], 0 );
		}
	}

	fn pushSliceToUstack( self: *Task, slice: []const usize ) void {
		self.stackBreak -= slice.len * @sizeOf( usize );
		@memcpy( @as( [*]usize, @ptrFromInt( self.stackBreak ) )[0..slice.len], slice );
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

pub fn createElf( reader: std.io.AnyReader, seeker: AnySeekableStream, bin: [:0]const u8, args: [2][]const [*:0]const u8 ) !*Task {
	const newTask = create( @ptrFromInt( 0xdeaddead ), false );
	newTask.bin = try root.kheap.dupeZ( u8, bin );
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
