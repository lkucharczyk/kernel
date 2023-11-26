const std = @import( "std" );
const root = @import( "root" );
const gdt = @import( "./gdt.zig" );
const irq = @import( "./irq.zig" );
const mem = @import( "./mem.zig" );
const vfs = @import( "./vfs.zig" );
const x86 = @import( "./x86.zig" );

pub var kernelTask: *Task = undefined;
pub var currentTask: *Task = undefined;

const KS = 64 * 1024;
const US = 64 * 1024;

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
		_: u12 = 0,

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

		if ( task.getFd( self.fd ) catch null ) |fd| {
			inline for ( .{ "read", "write" } ) |f| {
				if ( @field( fd.status, f ) and @field( self.reqEvents, f ) ) {
					@field( self.retEvents, f ) = true;
					out = true;
				}
			}
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

pub const Error = error {
	BadFileDescriptor,
	OutOfMemory,
	PermissionDenied,
	InvalidPointer,
	InvalidArgument,
	NotSocket,
	ProtocolNotSupported,
	AddressFamilyNotSupported,
	AddressInUse,
	NoRouteToHost
};

pub const Errno = enum(i16) {
	Success                   = 0,
	/// EBADF
	BadFileDescriptor         = 9,
	/// ENOMEM
	OutOfMemory               = 12,
	/// EACCES
	PermissionDenied          = 13,
	/// EFAULT
	InvalidPointer            = 14,
	/// EINVAL
	InvalidArgument           = 22,
	/// ENOTSOCK
	NotSocket                 = 88,
	/// EPROTONOSUPPORT
	ProtocolNotSupported      = 93,
	/// EAFNOSUPPORT
	AddressFamilyNotSupported = 97,
	/// EADDRINUSE
	AddressInUse              = 98,
	/// EHOSTUNREACH
	NoRouteToHost             = 113,

	pub fn fromError( self: Error ) Errno {
		return switch ( self ) {
			Error.BadFileDescriptor         => .BadFileDescriptor,
			Error.OutOfMemory               => .OutOfMemory,
			Error.PermissionDenied          => .PermissionDenied,
			Error.InvalidPointer            => .InvalidPointer,
			Error.InvalidArgument           => .InvalidArgument,
			Error.NotSocket                 => .NotSocket,
			Error.ProtocolNotSupported      => .ProtocolNotSupported,
			Error.AddressFamilyNotSupported => .AddressFamilyNotSupported,
			Error.AddressInUse              => .AddressInUse,
			Error.NoRouteToHost             => .NoRouteToHost
		};
	}

	pub fn getResult( self: Errno ) isize {
		return -@intFromEnum( self );
	}
};

pub const Task = struct {
	id: u8,
	status: Status,
	kernelMode: bool,
	entrypoint: *const fn( argc: usize, argv: [*]const [*:0]const u8 ) callconv(.C) void,
	stackPtr: x86.StackPtr = undefined,
	kstack: []align(4096) u8 = undefined,
	ustack: []align(4096) u8 = undefined,
	args: []const [*:0]const u8 = undefined,
	memBreak: usize = 0,
	memPages: std.ArrayListUnmanaged( u10 ) = undefined,
	fd: std.ArrayListUnmanaged( ?*vfs.FileDescriptor ) = undefined,
	errno: Errno = .Success,

	fn init( self: *Task ) std.mem.Allocator.Error!void {
		self.kstack = try root.kheap.alignedAlloc( u8, 4096, KS );
		errdefer root.kheap.free( self.kstack );
		self.ustack = try root.kheap.alignedAlloc( u8, 4096, US );
		errdefer root.kheap.free( self.ustack );
		@memset( self.ustack, 0 );

		self.memPages = try std.ArrayListUnmanaged( u10 ).initCapacity( root.kheap, 1 );
		errdefer {
			for ( self.memPages.items ) |i| {
				mem.freePhysical( i );
			}

			self.memPages.deinit( root.kheap );
		}

		if ( !self.kernelMode ) {
			self.memPages.appendAssumeCapacity( try mem.allocPhysical() );
		}

		self.args.ptr = undefined;
		self.args.len = 0;

		self.fd = try std.ArrayListUnmanaged( ?*vfs.FileDescriptor ).initCapacity( root.kheap, 3 );
		errdefer self.fd.deinit( root.kheap );
		self.fd.appendAssumeCapacity( try kernelTask.fd.items[0].?.node.open() );
		self.fd.appendAssumeCapacity( try kernelTask.fd.items[1].?.node.open() );
		self.fd.appendAssumeCapacity( try kernelTask.fd.items[2].?.node.open() );

		self.stackPtr = .{
			.ebp = @intFromPtr( self.kstack.ptr ) + KS - 4,
			.esp = @intFromPtr( self.kstack.ptr ) + KS - ( 9 * 4 ),
		};

		currentTask = self;
		kernelTask.stackPtr = x86.StackPtr.get();
		currentTask.stackPtr.set();

		const cs: u32 = if ( currentTask.kernelMode ) ( gdt.Segment.KERNEL_CODE ) else ( gdt.Segment.USER_CODE | 3 );
		const ds: u32 = if ( currentTask.kernelMode ) ( gdt.Segment.KERNEL_DATA ) else ( gdt.Segment.USER_DATA | 3 );

		asm volatile (
			\\ pushl %[ds]        // data segment offset
			\\ pushl %[sp]        // task stack ptr
			\\ pushf              // eflags
			\\ popl %%eax
			\\ orl $0x200, %%eax  // enable interrupts on iret
			\\ pushl %%eax
			\\ pushl %[cs]        // code segment offset
			\\ pushl %[ep]        // entrypoint
			::
			[sp] "{ecx}" ( @intFromPtr( currentTask.ustack.ptr ) + US - 4 ),
			[ep] "{ebx}" ( &run ),
			[cs] "{edx}" ( cs ),
			[ds] "{eax}" ( ds )
		);

		currentTask.stackPtr = x86.StackPtr.get();
		kernelTask.stackPtr.set();
		currentTask = kernelTask;
	}

	fn deinit( self: *Task ) void {
		for ( self.memPages.items ) |i| {
			mem.freePhysical( i );
		}

		self.memPages.deinit( root.kheap );

		root.kheap.free( self.ustack );
		root.kheap.free( self.kstack );
	}

	pub fn map( self: *Task ) void {
		// root.log.printUnsafe( "task.map: {any}\n", .{ self.memPages.items } );
		for ( self.memPages.items, 0.. ) |page, i| {
			mem.pagingDir.entries[i] = .{
				.addressLow = page,
				.flags = .{
					.user = true,
					.present = true,
					.writeable = true,
					.hugePage = true
				}
			};

			asm volatile ( "invlpg (%[page])" :: [page] "r" ( i ) );
		}
	}

	pub fn unmap( self: *Task ) void {
		for ( 0..self.memPages.items.len ) |i| {
			mem.pagingDir.entries[i].flags.present = false;
			asm volatile ( "invlpg (%[page])" :: [page] "r" ( i ) );
		}
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
			asm volatile ( "iret" );
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
};

var tasks: [8]?Task = undefined;
var tcc: u3 = 0;
var tcs: u3 = 0;

pub fn init() std.mem.Allocator.Error!void {
	tasks[0] = Task {
		.id = 0,
		.status = .Kernel,
		.kernelMode = true,
		.entrypoint = undefined,
		.fd = try std.ArrayListUnmanaged( ?*vfs.FileDescriptor ).initCapacity( root.kheap, 3 )
	};
	kernelTask = &tasks[0].?;
	kernelTask.fd.appendAssumeCapacity( try vfs.devNode.resolve( "com0" ).?.open() );
	kernelTask.fd.appendAssumeCapacity( try vfs.devNode.resolve( "com0" ).?.open() );
	kernelTask.fd.appendAssumeCapacity( try vfs.devNode.resolve( "com0" ).?.open() );

	for ( 1..tasks.len ) |i| {
		tasks[i] = null;
	}
}

pub fn create( entrypoint: *const fn( argc: usize, argv: [*]const [*:0]const u8 ) callconv(.C) void, kernelMode: bool ) *Task {
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
			tasks[tcc].?.init() catch unreachable;
			x86.enableInterrupts();

			return &( tasks[tcc].? );
		}
	}

	@panic( "Can't create a new task" );
}

pub fn createElf( stream: anytype, args: []const [*:0]const u8 ) !void {
	const header = try std.elf.Header.read( stream );
	var task = create( @ptrFromInt( @as( usize, @truncate( header.entry ) ) ), false );
	task.args = try root.kheap.dupe( [*:0]const u8, args );
	var sections = header.section_header_iterator( stream );

	x86.disableInterrupts();
	task.map();

	while ( sections.next() catch |err| return err ) |section| {
		if ( ( section.sh_flags & std.elf.SHF_ALLOC ) > 0 ) {
			const ptr = @as( [*]u8, @ptrFromInt( @as( usize, @truncate( section.sh_addr ) ) ) )[0..@truncate( section.sh_size )];

			task.memBreak = std.mem.alignForward( usize, @max( task.memBreak, @intFromPtr( ptr.ptr + ptr.len ) ), 4096 );
			while ( task.memBreak >= 0x40_0000 * task.memPages.items.len ) {
				try task.memPages.append( root.kheap, try mem.allocPhysical() );
				task.map();
			}

			if ( section.sh_type == std.elf.SHT_NOBITS ) {
				@memset( ptr, 0 );
			} else if ( section.sh_type != std.elf.SHT_NULL ) {
				try stream.seekableStream().seekTo( section.sh_offset );
				_ = try stream.reader().read( ptr );
			}

		}
	}

	task.unmap();
	x86.enableInterrupts();
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

fn run() noreturn {
	currentTask.entrypoint( currentTask.args.len, currentTask.args.ptr );
	while ( true ) {
		std.os.system.exit( 0 );
	}
}
