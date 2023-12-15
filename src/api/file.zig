const std = @import( "std" );
const system = @import( "./system.zig" );
const AnySeekableStream = @import( "../util/stream.zig" ).AnySeekableStream;

pub const FileStream = struct {
	fd: i32,

	fn read( self: *const FileStream, buf: []u8 ) anyerror!usize {
		return std.os.system.read( self.fd, buf.ptr, buf.len );
	}

	fn getEndPos( self: *const FileStream ) error{}!u64 {
		const pos = try self.getPos();
		const out = system.lseek( self.fd, 0, system.SEEK.END );
		try self.seekTo( pos );
		return out;
	}

	fn getPos( self: *const FileStream ) error{}!u64 {
		return system.lseek( self.fd, 0, system.SEEK.CUR );
	}

	fn seekBy( self: *const FileStream, offset: i64 ) error{}!void {
		_ = system.lseek( self.fd, @bitCast( @as( i32, @truncate( offset ) ) ), system.SEEK.CUR );
	}

	fn seekTo( self: *const FileStream, offset: u64 ) error{}!void {
		_ = system.lseek( self.fd, @truncate( offset ), system.SEEK.SET );
	}

	pub fn reader( self: *FileStream ) std.io.AnyReader {
		return .{
			.context = self,
			.readFn = @ptrCast( &read ),
		};
	}

	pub fn seekableStream( self: *FileStream ) AnySeekableStream {
		return .{
			.context = self,
			.fnGetEndPos = @ptrCast( &getEndPos ),
			.fnGetPos = @ptrCast( &getPos ),
			.fnSeekBy = @ptrCast( &seekBy ),
			.fnSeekTo = @ptrCast( &seekTo )
		};
	}
};
