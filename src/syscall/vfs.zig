const std = @import( "std" );
const root = @import( "root" );
const fmtUtil = @import( "../util/fmt.zig" );
const task = @import( "../task.zig" );
const vfs = @import( "../vfs.zig" );
const x86 = @import( "../x86.zig" );
const util = @import( "./util.zig" );

/// link( old: [*:0]const u8, new: [*:0]const u8 )
pub fn link( args: [6]usize, _: ?*x86.State, strace: bool ) task.Error!isize {
	const old = ( try util.extractCStr( args[0] ) )[1..];
	const new = ( try util.extractCStr( args[1] ) )[1..];
	if ( strace ) {
		root.log.printUnsafe( " \"/{s}\", \"/{s}\" ", .{ old, new } );
	}

	const node = vfs.rootNode.resolveDeep( old ) orelse return task.Error.MissingFile;

	var dir = vfs.rootNode;
	var split: usize = 0;
	if ( std.mem.lastIndexOfScalar( u8, new, '/' ) ) |s| {
		dir = vfs.rootNode.resolveDeep( new[0..s] ) orelse return task.Error.MissingFile;
		split = s + 1;
	}

	if ( dir.resolve( new[split..] ) ) |_| {
		return task.Error.FileExists;
	}

	try dir.link( node, new[split..] );
	return 0;
}

/// unlink( path: [*:0]const u8 )
pub fn unlink( args: [6]usize, _: ?*x86.State, strace: bool ) task.Error!isize {
	const path = ( try util.extractCStr( args[0] ) )[1..];
	if ( strace ) {
		root.log.printUnsafe( " \"/{s}\" ", .{ path } );
	}

	var dir = vfs.rootNode;
	var split: usize = 0;
	if ( std.mem.lastIndexOfScalar( u8, path, '/' ) ) |s| {
		dir = vfs.rootNode.resolveDeep( path[0..s] ) orelse return task.Error.MissingFile;
		split = s + 1;
	}

	if ( dir.vtable.unlink == null ) {
		return task.Error.PermissionDenied;
	}

	for ( dir.readdir() ) |*entry| {
		if ( std.mem.eql( u8, entry.name, path[split..] ) ) {
			try dir.vtable.unlink.?( dir, entry );
			return 0;
		}
	}

	return task.Error.MissingFile;
}

/// rename( old: [*:0]const u8, new: [*:0]const u8 )
pub fn rename( args: [6]usize, state: ?*x86.State, strace: bool ) task.Error!isize {
	const old = ( try util.extractCStr( args[0] ) )[1..];
	const new = ( try util.extractCStr( args[1] ) )[1..];
	if ( strace ) {
		root.log.printUnsafe( " \"/{s}\", \"/{s}\" ", .{ old, new } );
	}

	_ = try link( args, state, false );
	_ = try unlink( args, state, false );
	return 0;
}

const STATX = struct {
	pub const TYPE = std.os.linux.STATX_TYPE;
	pub const MODE = std.os.linux.STATX_MODE;
	pub const NLINK = std.os.linux.STATX_NLINK;
	pub const UID = std.os.linux.STATX_UID;
	pub const GID = std.os.linux.STATX_GID;
	pub const ATIME = std.os.linux.STATX_ATIME;
	pub const MTIME = std.os.linux.STATX_MTIME;
	pub const CTIME = std.os.linux.STATX_CTIME;
	pub const INO = std.os.linux.STATX_INO;
	pub const SIZE = std.os.linux.STATX_SIZE;
	pub const BLOCKS = std.os.linux.STATX_BLOCKS;
	// pub const BASIC_STATS = std.os.linux.STATX_BASIC_STATS;
	pub const BTIME = std.os.linux.STATX_BTIME;
};

/// statx( dirFd: ?fd_t, path: ?[*:0]const u8, flags: ?linux.AT, mask: ?linux.STATX, out: *linux.Statx )
pub fn statx( args: [6]usize, _: ?*x86.State, strace: bool ) task.Error!isize {
	const path: ?[:0]const u8 = if ( args[1] > 0 ) try util.extractCStr( args[1] ) else null;
	const out = try util.extractPtr( std.os.linux.Statx, args[4] );

	if ( strace ) {
		root.log.printUnsafe( " {}, {}, AT{{ {} }}, STATX{{ {} }}, {*} ", .{
			@as( isize, @bitCast( args[0] ) ),
			fmtUtil.OptionalStr { .data = path },
			fmtUtil.BitFlags( std.os.linux.AT ) { .data = @bitCast( args[2] ) },
			fmtUtil.BitFlags( STATX ) { .data = args[3] },
			out
		} );
	}

	const node: *vfs.Node = if ( @as( isize, @bitCast( args[0] ) ) == -100 ) (
		vfs.rootNode
	) else if ( @as( isize, @bitCast( args[0] ) ) != -1 ) (
		( try task.currentTask.getFd( args[0] ) ).node
	) else {
		return task.Error.NotImplemented;
	};

	out.mask = 0;

	if ( ( args[3] & STATX.TYPE ) == STATX.TYPE ) {
		out.mode = @as( u16, @intFromEnum( node.ntype ) ) << 12;
		out.mask |= STATX.TYPE;
	}

	if ( ( args[3] & STATX.INO ) == STATX.INO ) {
		out.ino = node.inode;
		out.mask |= STATX.INO;
	}

	inline for ( .{ .{ STATX.ATIME, "atime" }, .{ STATX.BTIME, "btime" }, .{ STATX.CTIME, "ctime" }, .{ STATX.MTIME, "mtime" } } ) |t| {
		if ( ( args[3] & t[0] ) == t[0] ) {
			@field( out, t[1] ) = .{ .tv_sec = 0, .tv_nsec = 0, .__pad1 = 0 };
			out.mask |= t[0];
		}
	}

	return 0;
}
