const std = @import( "std" );
const root = @import( "root" );
const RootVfs = @import( "./fs/root.zig" ).RootVfs;

pub const VTable = struct {
	open:    ?*const fn( node: *Node, fd: *FileDescriptor ) void = null,
	close:   ?*const fn( node: *Node ) void = null,

	// NodeType.File
	read:    ?*const fn( node: *Node, fd: *FileDescriptor, buf: []u8 ) u32 = null,
	write:   ?*const fn( node: *Node, fd: *FileDescriptor, buf: []const u8 ) u32 = null,

	// NodeType.Directory
	link:    ?*const fn( node: *Node, target: *Node ) std.mem.Allocator.Error!void = null,
	mkdir:   ?*const fn( node: *Node, name: [*:0]const u8 ) std.mem.Allocator.Error!*Node = null,
	readdir: ?*const fn( node: *Node ) []*Node = null
};

pub const NodeType = enum(u8) {
	Unknown    = 0,
	CharDevice = 2,
	Directory  = 4,
	File       = 8,
	Socket     = 12
};

pub const Node = struct {
	inode: u32,
	name: [64:0]u8,
	ntype: NodeType = .Unknown,
	ctx: *anyopaque = undefined,
	vtable: VTable,
	mountpoint: ?*Node = null,
	descriptors: std.ArrayListUnmanaged( *FileDescriptor ),

	pub inline fn init(
		self: *Node,
		inode: u32,
		name: [*:0]const u8,
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

		std.debug.assert( std.mem.len( name ) < 64 );
		@memcpy( &self.name, name );
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

	pub fn signal( self: *Node ) void {
		for ( self.descriptors.items ) |fd| {
			fd.ready = true;
		}
	}

	pub fn read( self: *Node, fd: *FileDescriptor, buf: []u8 ) u32 {
		if ( self.vtable.read ) |f| {
			return f( self, fd, buf );
		}

		return @bitCast( @as( i32, -1 ) );
	}

	pub fn write( self: *Node, fd: *FileDescriptor, buf: []const u8 ) u32 {
		if ( self.vtable.write ) |f| {
			return f( self, fd, buf );
		}

		return @bitCast( @as( i32, -1 ) );
	}

	pub fn link( self: *Node, target: *Node ) std.mem.Allocator.Error!void {
		if ( self.mountpoint ) |mnt| {
			return mnt.link( target );
		}

		std.debug.assert( self.ntype == .Directory );
		return self.vtable.link.?( self, target );
	}

	pub fn mkdir( self: *Node, name: [*:0]const u8 ) std.mem.Allocator.Error!*Node {
		if ( self.mountpoint ) |mnt| {
			return mnt.mkdir( name );
		}

		std.debug.assert( self.ntype == .Directory );
		return self.vtable.mkdir.?( self, name );
	}

	pub fn readdir( self: *Node ) []*Node {
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

		for ( self.readdir() ) |node| {
			if ( std.mem.eql( u8, name, node.name[0..std.mem.indexOfSentinel( u8, 0, &node.name )] ) ) {
				return node;
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
	node: *Node,
	ready: bool = false,
	offset: usize = 0,

	fn init( self: *FileDescriptor, node: *Node ) void {
		self.node = node;
		self.ready = false;
		self.offset = 0;
	}

	pub fn getSocket( self: FileDescriptor ) ?*@import( "./net.zig" ).Socket {
		if ( self.node.ntype == .Socket ) {
			return @alignCast( @ptrCast( self.node.ctx ) );
		}

		return null;
	}

	pub fn read( self: *FileDescriptor, buf: []u8 ) u32 {
		return self.node.read( self, buf );
	}

	pub fn write( self: *FileDescriptor, buf: []const u8 ) u32 {
		return self.node.write( self, buf );
	}
};

pub fn printTree( node: *Node, indent: usize ) void {
	for ( 0..indent ) |_| {
		root.log.printUnsafe( "    ", .{} );
	}

	switch ( node.ntype ) {
		.Directory => {
			root.log.printUnsafe( "{s}/\n", .{ node.name } );
			for ( node.readdir() ) |sn| {
				printTree( sn, indent + 1 );
			}
		},
		else => {
			root.log.printUnsafe( "{s}\n", .{ node.name } );
		}
	}
}

var descriptorPool: std.heap.MemoryPoolExtra( FileDescriptor, .{} ) = undefined;
var rootVfs: RootVfs = undefined;
pub var rootNode: *Node = undefined;
pub var devNode: *Node = undefined;

pub fn init() std.mem.Allocator.Error!void {
	descriptorPool = try std.heap.MemoryPoolExtra( FileDescriptor, .{} ).initPreheated( root.kheap, 32 );
	rootNode = try rootVfs.init( root.kheap );
	devNode = try rootNode.mkdir( "dev" );
}
