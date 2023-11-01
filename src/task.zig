const std = @import( "std" );
const root = @import( "root" );
const gdt = @import( "./gdt.zig" );
const irq = @import( "./irq.zig" );
const vfs = @import( "./vfs.zig" );
const x86 = @import( "./x86.zig" );

pub var kernelTask: *Task = undefined;
pub var currentTask: *Task = undefined;

const KS = 32 * 1024;
const US = 32 * 1024;

const Status = enum {
	Kernel,
	Start,
	Wait,
	Active,
	Done
};

pub const Task = struct {
	id: u8,
	status: Status,
	kernelMode: bool,
	entrypoint: *const fn() void,
	stackPtr: x86.StackPtr = undefined,
	kstack: []align(4096) u8 = undefined,
	ustack: []align(4096) u8 = undefined,
	fd: std.ArrayListUnmanaged( ?vfs.FileDescriptor ) = undefined,

	fn init( self: *Task ) std.mem.Allocator.Error!void {
		self.kstack = try root.kheap.alignedAlloc( u8, 4096, KS );
		self.ustack = try root.kheap.alignedAlloc( u8, 4096, US );

		self.fd = try std.ArrayListUnmanaged( ?vfs.FileDescriptor ).initCapacity( root.kheap, 3 );
		self.fd.appendAssumeCapacity( kernelTask.fd.items[0] );
		self.fd.appendAssumeCapacity( kernelTask.fd.items[1] );
		self.fd.appendAssumeCapacity( kernelTask.fd.items[2] );

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
		root.kheap.free( self.ustack );
		root.kheap.free( self.kstack );
	}

	fn enter( self: *Task ) void {
		gdt.tss.esp0 = @intFromPtr( self.kstack.ptr ) + KS - ( 9 * 4 );

		currentTask.stackPtr = x86.StackPtr.get();
		currentTask = self;
		currentTask.stackPtr.set();

		if ( currentTask.status == .Start ) {
			currentTask.status = .Active;
			asm volatile ( "iret" );
		}

		asm volatile ( "task_end:" );
	}

	pub fn park( self: *Task ) void {
		self.status = .Wait;
		if ( currentTask == self ) {
			asm volatile ( "int $0x20" );
		}
	}

	pub fn exit( self: *Task, code: u32 ) noreturn {
		x86.disableInterrupts();
		self.status = .Done;
		root.log.printUnsafe( "\nTask {} exited with code {}.\n", .{ self.id, code } );

		currentTask = self;
		kernelTask.stackPtr.set();
		gdt.tss.esp0 = 0;
		currentTask = kernelTask;

		asm volatile ( "jmp task_end" );
		x86.halt();
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
		.fd = try std.ArrayListUnmanaged( ?vfs.FileDescriptor ).initCapacity( root.kheap, 3 )
	};
	kernelTask = &tasks[0].?;
	kernelTask.fd.appendNTimesAssumeCapacity( .{ .node = vfs.devNode.resolve( "com0" ).? }, 3 );

	for ( 1..tasks.len ) |i| {
		tasks[i] = null;
	}
}

pub fn create( entrypoint: *const fn() void, kernelMode: bool ) *Task {
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

pub fn schedule() void {
	x86.disableInterrupts();
	irq.set( irq.Interrupt.Pit, scheduler );

	while ( true ) {
		currentTask = kernelTask;
		// ticks = @import( "std" ).math.maxInt( @TypeOf( ticks ) );
		asm volatile ( "int %[irq]" :: [irq] "n" ( irq.Interrupt.Pit ) );

		// root.log.printUnsafe( "S ", .{} );

		var c: usize = 0;
		for ( 1..tasks.len ) |i| {
			if ( tasks[i] ) |*t| {
				if ( t.status == .Start or t.status == .Active ) {
					c += 1;
				} else if ( t.status == .Done ) {
					t.deinit();
					tasks[tcs] = null;
				}
			}
		}

		if ( c == 0 ) {
			break;
		}
	}

	root.log.printUnsafe( "\nAll tasks completed.\n", .{} );
	irq.unset( irq.Interrupt.Pit );
	x86.enableInterrupts();
}

// var ticks: u1 = @import( "std" ).math.maxInt( u1 );
fn scheduler( _: *x86.State ) void {
	// ticks +%= 1;
	// if ( ticks > 0 ) {
	//	return;
	// }

	// root.log.printUnsafe( "s ", .{} );
	for ( 0..tasks.len ) |_| {
		tcs +%= 1;

		if ( tasks[tcs] ) |*t| {
			if ( t.status != .Start and t.status != .Active ) {
				if ( t.status == .Done ) {
					t.deinit();
					tasks[tcs] = null;
				}

				continue;
			}

			x86.out( u8, irq.Register.Pic1Command, irq.Command.EndOfInterrupt );
			t.enter();
			return;
		}
	}
}

fn run() void {
	currentTask.entrypoint();
	_ = @import( "./syscall.zig" ).call( .Exit, .{ 0 } );
}
