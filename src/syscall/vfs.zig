const std = @import( "std" );
const root = @import( "root" );
const fmtUtil = @import( "../util/fmt.zig" );
const task = @import( "../task.zig" );
const vfs = @import( "../vfs.zig" );
const x86 = @import( "../x86.zig" );
const util = @import( "./util.zig" );

/// link( old: [*:0]const u8, new: [*:0]const u8 )
pub fn link( args: [6]usize, _: ?*x86.State, strace: bool ) task.Error!isize {
	const old = try util.extractPath( args[0] );
	const new = try util.extractPath( args[1] );
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
	const path = try util.extractPath( args[0] );
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
	const old = try util.extractPath( args[0] );
	const new = try util.extractPath( args[1] );
	if ( strace ) {
		root.log.printUnsafe( " \"/{s}\", \"/{s}\" ", .{ old, new } );
	}

	_ = try link( args, state, false );
	_ = try unlink( args, state, false );
	return 0;
}

const STATX = packed struct(u32) {
	TYPE: bool = false,
	MODE: bool = false,
	NLINK: bool = false,
	UID: bool = false,
	GID: bool = false,
	ATIME: bool = false,
	MTIME: bool = false,
	CTIME: bool = false,
	INO: bool = false,
	SIZE: bool = false,
	BLOCKS: bool = false,
	BTIME: bool = false,
	_: u20 = 0
};

/// statx( dirFd: ?fd_t, path: ?[*:0]const u8, flags: ?linux.AT, mask: ?linux.STATX, out: *linux.Statx )
pub fn statx( args: [6]usize, _: ?*x86.State, strace: bool ) task.Error!isize {
	const path: ?[:0]const u8 = if ( args[1] > 0 ) try util.extractCStr( args[1] ) else null;
	const req: STATX = @bitCast( args[3] );
	const out = try util.extractPtr( std.os.linux.Statx, args[4] );

	if ( strace ) {
		root.log.printUnsafe( " {}, {}, AT{{ {} }}, STATX{{ {} }}, {*} ", .{
			@as( isize, @bitCast( args[0] ) ),
			fmtUtil.OptionalStr { .data = path },
			fmtUtil.BitFlags( std.os.linux.AT ) { .data = @bitCast( args[2] ) },
			fmtUtil.BitFlagsStruct( STATX ) { .data = req },
			out
		} );
	}

	const node: *vfs.Node = if ( @as( isize, @bitCast( args[0] ) ) == -100 ) (
		if ( path ) |p| (
			vfs.rootNode.resolveDeep( p[1..] ) orelse return task.Error.MissingFile
		) else (
			vfs.rootNode
		)
	) else if ( @as( isize, @bitCast( args[0] ) ) != -1 ) (
		( try task.currentTask.getFd( args[0] ) ).node
	) else {
		return task.Error.NotImplemented;
	};

	var mask = STATX {};

	out.mode = 0;
	if ( req.MODE ) {
		out.mode |= 0o555;
		mask.TYPE = true;
	}

	if ( req.TYPE ) {
		out.mode |= @as( u16, @intFromEnum( node.ntype ) ) << 12;
		mask.TYPE = true;
	}

	if ( req.INO ) {
		out.ino = node.inode;
		mask.INO = true;
	}

	if ( req.SIZE ) {
		if ( node.stat( .{ .size = true } ) catch null ) |res| {
			if ( res.size ) |size| {
				out.size = size;
				mask.SIZE = true;
			}
		}
	}

	inline for ( .{ .{ "ATIME", "atime" }, .{ "BTIME", "btime" }, .{ "CTIME", "ctime" }, .{ "MTIME", "mtime" } } ) |t| {
		if ( @field( req, t[0] ) ) {
			@field( out, t[1] ) = .{ .tv_sec = 0, .tv_nsec = 0, .__pad1 = 0 };
			@field( mask, t[0] ) = true;
		}
	}

	out.mask = @bitCast( mask );
	return 0;
}
