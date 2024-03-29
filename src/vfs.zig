const std = @import( "std" );
const root = @import( "root" );
const task = @import( "./task.zig" );
const AnySeekableStream = @import( "./util/stream.zig" ).AnySeekableStream;
const RootVfs = @import( "./fs/root.zig" ).RootVfs;

pub const VTable = struct {
	open:    ?*const fn( node: *Node, fd: *FileDescriptor ) void = null,
	close:   ?*const fn( node: *Node ) void = null,
	ioctl:   ?*const fn( node: *Node, fd: *FileDescriptor, cmd: u32, arg: usize ) task.Error!i32 = null,
	stat:    ?*const fn( node: *Node, req: Stat.Request ) task.Error!Stat = null,

	// NodeType.File
	read:    ?*const fn( node: *Node, fd: *FileDescriptor, buf: []u8 ) task.Error!u32 = null,
	write:   ?*const fn( node: *Node, fd: *FileDescriptor, buf: []const u8 ) task.Error!u32 = null,

	// NodeType.Directory
	link:    ?*const fn( node: *Node, target: *Node, name: []const u8 ) std.mem.Allocator.Error!void = null,
	unlink:  ?*const fn( node: *Node, target: *const Link ) error{ MissingFile }!void = null,
	mkdir:   ?*const fn( node: *Node, name: []const u8 ) std.mem.Allocator.Error!*Node = null,
	readdir: ?*const fn( node: *Node ) []const Link = null
};

pub const Stat = struct {
	pub const Request = struct {
		size: bool
	};

	size: ?u64
};

pub const Link = struct {
	name: [:0]const u8,
	node: *Node
};

pub const NodeType = enum(u8) {
	Unknown     = 0o00,
	CharDevice  = 0o02,
	Directory   = 0o04,
	BlockDevice = 0o06,
	File        = 0o10,
	Symlink     = 0o12,
	Socket      = 0o14
};

pub const Node = struct {
	inode: u32,
	ntype: NodeType = .Unknown,
	ctx: *anyopaque = undefined,
	vtable: VTable,
	mountpoint: ?*Node = null,
	descriptors: std.ArrayListUnmanaged( *FileDescriptor ),

	pub inline fn init(
		self: *Node,
		inode: u32,
		ntype: NodeType,
		ctx: *anyopaque,
		vtable: VTable
	) void {
		self.inode = inode;
		self.ntype = ntype;
		self.ctx = ctx;
		self.vtable = vtable;
		self.mountpoint = null;
		self.descriptors = .{};
	}

	pub fn open( self: *Node ) error{ OutOfMemory }!*FileDescriptor {
		const fd = try descriptorPool.create();
		fd.init( self );
		try self.descriptors.append( root.kheap, fd );

		if ( self.vtable.open ) |f| {
			f( self, fd );
		}

		return fd;
	}

	pub fn close( self: *Node, fd: *FileDescriptor ) void {
		if ( self.vtable.close ) |f| {
			return f( self );
		}

		for ( self.descriptors.items, 0.. ) |nfd, i| {
			if ( nfd == fd ) {
				_ = self.descriptors.swapRemove( i );
				break;
			}
		}

		descriptorPool.destroy( fd );
	}

	pub fn signal( self: *Node, changes: FileDescriptor.Signal ) void {
		for ( self.descriptors.items ) |fd| {
			inline for ( @typeInfo( FileDescriptor.Signal ).Struct.fields ) |f| {
				if ( @field( changes, f.name ) ) |v| {
					@field( fd.status, f.name ) = v;
				}
			}
		}
	}

	pub inline fn stat( self: *Node, req: Stat.Request ) task.Error!Stat {
		if ( self.vtable.stat ) |f| {
			return f( self, req );
		}

		return task.Error.NotImplemented;
	}

	pub fn link( self: *Node, target: *Node, name: []const u8 ) error{ PermissionDenied, NotDirectory, OutOfMemory }!void {
		if ( self.mountpoint ) |mnt| {
			return mnt.link( target, name );
		}

		if ( self.vtable.link ) |f| {
			return f( self, target, name );
		}

		if ( self.ntype != .Directory ) {
			return task.Error.NotDirectory;
		}

		return task.Error.PermissionDenied;
	}

	pub fn mkdir( self: *Node, name: []const u8 ) std.mem.Allocator.Error!*Node {
		if ( self.mountpoint ) |mnt| {
			return mnt.mkdir( name );
		}

		std.debug.assert( self.ntype == .Directory );
		return self.vtable.mkdir.?( self, name );
	}

	pub fn readdir( self: *Node ) []const Link {
		if ( self.mountpoint ) |mnt| {
			return mnt.readdir();
		}

		std.debug.assert( self.ntype == .Directory );
		return self.vtable.readdir.?( self );
	}

	pub fn mount( self: *Node, target: *Node ) void {
		std.debug.assert(
			self.mountpoint == null
			and self.ntype == .Directory
			and target.ntype == .Directory
		);

		self.mountpoint = target;
	}

	pub fn umount( self: *Node ) void {
		self.mountpoint = null;
	}

	pub fn resolve( self: *Node, name: []const u8 ) ?*Node {
		std.debug.assert( self.ntype == .Directory );

		for ( self.readdir() ) |e| {
			if ( std.mem.eql( u8, name, e.name ) ) {
				return e.node;
			}
		}

		return null;
	}

	pub fn resolveDeep( self: *Node, path: []const u8 ) ?*Node {
		std.debug.assert( self.ntype == .Directory );

		var cur: *Node = self;
		var iter = std.mem.splitScalar( u8, path, '/' );
		while ( iter.next() ) |subpath| {
			if ( cur.resolve( subpath ) ) |next| {
				cur = next;
			} else {
				return null;
			}
		}

		return cur;
	}

	pub fn format( self: Node, _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		try std.fmt.format( writer,
			"{s}{{ .inode = {}, .name = \"{s}\", .ntype = {}, .ctx = {*}, .vtable = {*} }}",
			.{ @typeName( Node ), self.inode, self.name, self.ntype, self.ctx, self.vtable }
		);
	}
};

pub const FileDescriptor = struct {
	pub const Signal = struct {
		read: ?bool = null,
		write: ?bool = null,
		other: ?bool = null
	};

	pub const Status = struct {
		read: bool = false,
		write: bool = false,
		other: bool = false
	};

	node: *Node,
	status: Status = .{},
	ready: bool = false,
	offset: usize = 0,

	fn init( self: *FileDescriptor, node: *Node ) void {
		self.node = node;
		self.status = .{};
		self.ready = false;
		self.offset = 0;
	}

	pub fn getSocket( self: FileDescriptor ) ?*@import( "./net.zig" ).Socket {
		if ( self.node.ntype == .Socket ) {
			return @alignCast( @ptrCast( self.node.ctx ) );
		}

		return null;
	}

	pub inline fn close( self: *FileDescriptor ) void {
		self.node.close( self );
	}

	pub fn read( self: *FileDescriptor, buf: []u8 ) task.Error!u32 {
		if ( self.node.vtable.read ) |f| {
			return f( self.node, self, buf );
		}

		if ( self.node.ntype == .Directory ) {
			return task.Error.IsDirectory;
		}

		return task.Error.BadFileDescriptor;
	}

	pub fn write( self: *FileDescriptor, buf: []const u8 ) task.Error!u32 {
		if ( self.node.vtable.write ) |f| {
			return f( self.node, self, buf );
		}

		if ( self.node.ntype == .Directory ) {
			return task.Error.IsDirectory;
		}

		return task.Error.BadFileDescriptor;
	}

	pub fn getEndPos( self: *FileDescriptor ) error{}!u64 {
		_ = self;
		return 0;
	}

	pub fn getPos( self: *FileDescriptor ) error{}!u64 {
		return self.offset;
	}

	pub fn seekBy( self: *FileDescriptor, offset: i64 ) error{}!void {
		if ( offset < 0 ) {
			self.offset -|= @as( usize, @truncate( @abs( offset ) ) );
		} else {
			self.offset +|= @as( usize, @truncate( @abs( offset ) ) );
		}
	}

	pub fn seekTo( self: *FileDescriptor, offset: u64 ) error{}!void {
		self.offset = @truncate( offset );
	}

	pub fn reader( self: *FileDescriptor ) std.io.AnyReader {
		return .{
			.context = self,
			.readFn = @ptrCast( &read )
		};
	}

	pub fn seekableStream( self: *FileDescriptor ) AnySeekableStream {
		return .{
			.context = self,
			.fnGetEndPos = @ptrCast( &getEndPos ),
			.fnGetPos = @ptrCast( &getPos ),
			.fnSeekBy = @ptrCast( &seekBy ),
			.fnSeekTo = @ptrCast( &seekTo )
		};
	}
};

pub fn printTree( node: *Node, name: [:0]const u8, indent: usize ) void {
	for ( 0..indent ) |_| {
		root.log.printUnsafe( "    ", .{} );
	}

	switch ( node.ntype ) {
		.Directory => {
			root.log.printUnsafe( "{s}/\n", .{ name } );
			for ( node.readdir() ) |sn| {
				printTree( sn.node, sn.name, indent + 1 );
			}
		},
		else => {
			root.log.printUnsafe( "{s}\n", .{ name } );
		}
	}
}

var descriptorPool: std.heap.MemoryPoolExtra( FileDescriptor, .{} ) = undefined;
pub var rootVfs: RootVfs = undefined;
pub var rootNode: *Node = undefined;
pub var devNode: *Node = undefined;

pub fn init() std.mem.Allocator.Error!void {
	descriptorPool = try std.heap.MemoryPoolExtra( FileDescriptor, .{} ).initPreheated( root.kheap, 32 );
	rootNode = try rootVfs.init( root.kheap );
	devNode = try rootNode.mkdir( "dev" );
}
