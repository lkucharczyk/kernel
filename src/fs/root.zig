const std = @import( "std" );
const root = @import( "root" );
const vfs = @import( "../vfs.zig" );

const FileContext = struct {
	fs: *RootVfs,
	data: []const u8
};

const DirContext = struct {
	fs: *RootVfs,
	parent: ?*vfs.Node = null,
	subnodes: std.ArrayListUnmanaged( *vfs.Node ) = std.ArrayListUnmanaged( *vfs.Node ) {},
	mount: ?*vfs.Node = null
};

pub const RootVfs = struct {
	const fileVTable = vfs.VTable {
		.read = &read
	};

	const dirVTable = vfs.VTable {
		.link = &linkAt,
		.mkdir = &createDirAt,
		.readdir = &readDir,
	};

	allocator: std.mem.Allocator,
	nodePool: std.heap.MemoryPoolExtra( vfs.Node, .{} ),
	filePool: std.heap.MemoryPoolExtra( FileContext, .{} ),
	dirPool: std.heap.MemoryPoolExtra( DirContext, .{} ),
	root: *vfs.Node,

	pub fn init( self: *RootVfs, allocator: std.mem.Allocator ) std.mem.Allocator.Error!*vfs.Node {
		self.allocator = allocator;
		self.nodePool = try std.heap.MemoryPoolExtra( vfs.Node, .{} ).initPreheated( allocator, 8 );
		self.filePool = try std.heap.MemoryPoolExtra( FileContext, .{} ).initPreheated( allocator, 4 );
		self.dirPool = try std.heap.MemoryPoolExtra( DirContext, .{} ).initPreheated( allocator, 4 );

		self.root = try self.createDir( null, "[RootVFS]" );
		return self.root;
	}

	fn createDir( self: *RootVfs, parent: ?*vfs.Node, name: [*:0]const u8 ) std.mem.Allocator.Error!*vfs.Node {
		var node = try self.nodePool.create();
		const ctx = try self.dirPool.create();

		ctx.* = .{
			.fs = self,
			.parent = parent,
			.subnodes = try std.ArrayListUnmanaged( *vfs.Node ).initCapacity( self.allocator, 4 )
		};

		node.init( 1, name, .Directory, ctx, RootVfs.dirVTable );

		return node;
	}

	pub fn createDirAt( node: *vfs.Node, name: [*:0]const u8 ) std.mem.Allocator.Error!*vfs.Node {
		var ctx: *DirContext = @alignCast( @ptrCast( node.ctx ) );

		if ( ctx.mount ) |mnt| {
			return mnt.mkdir( name );
		}

		const newNode = try ctx.fs.createDir( node, name );
		try ctx.subnodes.append( ctx.fs.allocator, newNode );

		return newNode;
	}

	pub fn createRoFile( self: *RootVfs, name: [*:0]const u8, data: []const u8 ) std.mem.Allocator.Error!*vfs.Node {
		var node = try self.nodePool.create();
		const ctx = try self.filePool.create();

		ctx.* = .{
			.fs = self,
			.data = data
		};

		node.init( 1, name, .File, ctx, RootVfs.fileVTable );
		return node;
	}

	pub fn read( node: *vfs.Node, fd: *vfs.FileDescriptor, buf: []u8 ) usize {
		const ctx: *FileContext = @alignCast( @ptrCast( node.ctx ) );

		if ( fd.offset >= ctx.data.len ) {
			return 0;
		}

		const len = @min( ctx.data.len - fd.offset, buf.len );
		@memcpy( buf[0..len], ctx.data[fd.offset..( fd.offset + len )] );
		fd.offset += len;
		return len;
	}

	pub fn linkAt( node: *vfs.Node, target: *vfs.Node ) std.mem.Allocator.Error!void {
		const ctx: *DirContext = @alignCast( @ptrCast( node.ctx ) );
		( try ctx.subnodes.addOne( ctx.fs.allocator ) ).* = target;
	}

	pub fn readDir( node: *vfs.Node ) []*vfs.Node {
		const ctx: *DirContext = @alignCast( @ptrCast( node.ctx ) );
		return if ( ctx.mount ) |mnt| ( mnt.readdir() ) else ( ctx.subnodes.items );
	}

	pub fn mount( node: *vfs.Node, target: *vfs.Node ) void {
		const ctx: *DirContext = @alignCast( @ptrCast( node.ctx ) );
		ctx.mount = target;
	}

	pub fn umount( node: *vfs.Node ) void {
		const ctx: *DirContext = @alignCast( @ptrCast( node.ctx ) );
		ctx.mount = null;
	}
};
