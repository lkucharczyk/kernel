const std = @import( "std" );
const root = @import( "root" );
const gdt = @import( "./gdt.zig" );
const irq = @import( "./irq.zig" );
const x86 = @import( "./x86.zig" );

var kernelTask: *Task = undefined;
var currentTask: *Task = undefined;

const KS = 1024;
const US = 1024;

const Status = enum {
	Kernel,
	Start,
	Active,
	Done
};

const Task = struct {
	id: u8,
	status: Status,
	entrypoint: *const fn() void,
	stackPtr: x86.StackPtr = undefined,
	kstack: [KS]u8 = .{ 0 } ** KS,
	ustack: [US]u8 = .{ 0 } ** US,

	fn init( self: *Task ) void {
		self.stackPtr = .{
			.ebp = @intFromPtr( &self.kstack ) + KS - 4,
			.esp = @intFromPtr( &self.kstack ) + KS - ( 9 * 4 )
		};

		currentTask = self;
		x86.saveState( false );
		kernelTask.stackPtr = x86.StackPtr.get();
		currentTask.stackPtr.set();

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
			[sp] "{ecx}" ( @intFromPtr( &currentTask.ustack ) + US - 4 ),
			[ep] "{ebx}" ( &run ),
			[cs] "n" ( gdt.Segment.USER_CODE | 3 ),
			[ds] "n" ( gdt.Segment.USER_DATA | 3 )
		);

		currentTask.stackPtr = x86.StackPtr.get();
		kernelTask.stackPtr.set();
		x86.restoreState();
		currentTask = kernelTask;
	}

	fn enter( self: *Task ) void {
		gdt.tss.esp0 = @intFromPtr( &self.kstack ) + KS - ( 9 * 4 );

		currentTask.stackPtr = x86.StackPtr.get();
		currentTask = self;
		currentTask.stackPtr.set();

		if ( currentTask.status == .Start ) {
			currentTask.status = .Active;
			asm volatile ( "iret" );
		}

		asm volatile ( "task_end:" );
	}
};

var tasks: [8]?Task = undefined;
var tcc: u3 = 0;
var tcs: u3 = 0;

pub fn init() void {
	tasks[0] = Task { .id = 0, .status = .Kernel, .entrypoint = undefined };
	kernelTask = &tasks[0].?;

	for ( 1..tasks.len ) |i| {
		tasks[i] = null;
	}

	irq.set( irq.Interrupt.Syscall, exit );
}

pub fn create( entrypoint: *const fn() void ) void {
	for ( 0..tasks.len ) |_| {
		tcc +%= 1;

		if ( tasks[tcc] == null ) {
			x86.disableInterrupts();
			tasks[tcc] = Task {
				.id = tcc,
				.status = .Start,
				.entrypoint = entrypoint
			};
			tasks[tcc].?.init();
			x86.enableInterrupts();

			return;
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

		root.log.printUnsafe( "S ", .{} );

		var c: usize = 0;
		for ( 1..tasks.len ) |i| {
			if ( tasks[i] ) |t| {
				if ( t.status == .Start or t.status == .Active ) {
					c += 1;
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

	root.log.printUnsafe( "s ", .{} );
	for ( 0..tasks.len ) |_| {
		tcs +%= 1;

		if ( tasks[tcs] ) |*t| {
			if ( t.status != .Start and t.status != .Active ) {
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
	asm volatile ( "int $0x80" );
}

fn exit( _: *x86.State ) void {
	kernelTask.stackPtr.set();
	root.log.printUnsafe( "\nTask {} completed.\n", .{ currentTask.id } );
	tasks[currentTask.id] = null;
	currentTask = kernelTask;

	asm volatile ( "jmp task_end" );
}
