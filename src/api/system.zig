const std = @import( "std" );

pub const PATH_MAX = 64;

pub const STDIN_FILENO = std.os.linux.STDIN_FILENO;
pub const STDOUT_FILENO = std.os.linux.STDERR_FILENO;
pub const STDERR_FILENO = std.os.linux.STDERR_FILENO;

pub const E = std.os.linux.E;
pub const SEEK = std.os.linux.SEEK;

pub const fd_t = std.os.linux.fd_t;
pub const ino_t = std.os.linux.ino_t;
pub const mode_t = std.os.linux.mode_t;
pub const time_t = i64;

pub const sockaddr = std.os.linux.sockaddr;
pub const timeval = extern struct {
	tv_sec: time_t,
	tv_usec: i32
};

pub const getErrno = std.os.linux.getErrno;

pub const close = std.os.linux.close;
pub const execve = std.os.linux.execve;
pub const exit = std.os.linux.exit;
pub const getpid = std.os.linux.getpid;
pub const fork = std.os.linux.fork;
pub const ioctl = std.os.linux.ioctl;
pub const open = std.os.linux.open;
pub const read = std.os.linux.read;
pub const vfork = std.os.linux.vfork;
pub const write = std.os.linux.write;

pub fn brk( ptr: usize ) usize {
	return asm volatile (
		\\ int $0x80
		: [_] "={eax}" (-> usize)
		: [_] "{eax}" ( 45 ), [_] "{ebx}" ( ptr )
	);
}

var _brk: usize = 0;
pub fn sbrk( inc: usize ) usize {
	if ( _brk == 0 ) {
		_brk = brk( 0 );
	}

	if ( inc == 0 ) {
		return _brk;
	}

	const out = _brk;
	_brk = brk( _brk + inc );

	return out;
}

pub fn isatty( fd: fd_t ) isize {
	var ws: std.os.linux.winsize = undefined;
	return ioctl( fd, std.os.linux.T.IOCGWINSZ, @intFromPtr( &ws ) ) == 0;
}

pub fn lseek( fd: fd_t, offset: usize, whence: usize ) usize {
	return asm volatile (
		"int $0x80"
		: [_] "={eax}" (-> usize)
		:
		[_] "{eax}" ( std.os.linux.SYS.lseek ),
		[_] "{ebx}" ( fd ),
		[_] "{ecx}" ( offset ),
		[_] "{edx}" ( whence )
	);
}
