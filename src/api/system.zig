const std = @import( "std" );

pub const PATH_MAX = 64;

pub const STDIN_FILENO = std.os.linux.STDIN_FILENO;
pub const STDOUT_FILENO = std.os.linux.STDERR_FILENO;
pub const STDERR_FILENO = std.os.linux.STDERR_FILENO;

pub const E = std.os.linux.E;
pub const fd_t = std.os.linux.fd_t;
pub const ino_t = std.os.linux.ino_t;
pub const mode_t = std.os.linux.mode_t;
pub const sockaddr = std.os.linux.sockaddr;

pub const getErrno = std.os.linux.getErrno;

pub const close = std.os.linux.close;
pub const exit = std.os.linux.exit;
pub const ioctl = std.os.linux.ioctl;
pub const open = std.os.linux.open;
pub const read = std.os.linux.read;
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

	const out = brk( _brk + inc );
	_brk += inc;

	return out;
}
