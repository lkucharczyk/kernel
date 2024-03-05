const std = @import( "std" );

pub const Error = error {
	OperationNotPermitted,
	MissingFile,
	IoError,
	BadFileDescriptor,
	ResourceUnavailable,
	OutOfMemory,
	PermissionDenied,
	InvalidPointer,
	FileExists,
	NotDirectory,
	IsDirectory,
	InvalidArgument,
	OutOfRange,
	NotImplemented,
	NotSocket,
	MissingDestinationAddress,
	ProtocolNotSupported,
	AddressFamilyNotSupported,
	AddressInUse,
	NoRouteToHost
};

pub const Errno = enum(i16) {
	Success                   = 0,
	/// EPERM
	OperationNotPermitted     = 1,
	/// ENOENT
	MissingFile               = 2,
	/// EIO
	IoError                   = 5,
	/// EBADF
	BadFileDescriptor         = 9,
	/// EAGAIN
	ResourceUnavailable       = 11,
	/// ENOMEM
	OutOfMemory               = 12,
	/// EACCES
	PermissionDenied          = 13,
	/// EFAULT
	InvalidPointer            = 14,
	/// EEXIST
	FileExists                = 17,
	/// ENOTDIR
	NotDirectory              = 20,
	/// EISDIR
	IsDirectory               = 21,
	/// EINVAL
	InvalidArgument           = 22,
	/// ERANGE
	OutOfRange                = 34,
	/// ENOSYS
	NotImplemented            = 38,
	/// ENOTSOCK
	NotSocket                 = 88,
	/// EDESTADDRREQ
	MissingDestinationAddress = 89,
	/// EPROTONOSUPPORT
	ProtocolNotSupported      = 93,
	/// EAFNOSUPPORT
	AddressFamilyNotSupported = 97,
	/// EADDRINUSE
	AddressInUse              = 98,
	/// EHOSTUNREACH
	NoRouteToHost             = 113,

	pub fn fromError( self: Error ) Errno {
		return switch ( self ) {
			Error.OperationNotPermitted     => .OperationNotPermitted,
			Error.MissingFile               => .MissingFile,
			Error.IoError                   => .IoError,
			Error.BadFileDescriptor         => .BadFileDescriptor,
			Error.ResourceUnavailable       => .ResourceUnavailable,
			Error.OutOfMemory               => .OutOfMemory,
			Error.PermissionDenied          => .PermissionDenied,
			Error.InvalidPointer            => .InvalidPointer,
			Error.FileExists                => .FileExists,
			Error.NotDirectory              => .NotDirectory,
			Error.IsDirectory               => .IsDirectory,
			Error.InvalidArgument           => .InvalidArgument,
			Error.OutOfRange                => .OutOfRange,
			Error.NotImplemented            => .NotImplemented,
			Error.NotSocket                 => .NotSocket,
			Error.MissingDestinationAddress => .MissingDestinationAddress,
			Error.ProtocolNotSupported      => .ProtocolNotSupported,
			Error.AddressFamilyNotSupported => .AddressFamilyNotSupported,
			Error.AddressInUse              => .AddressInUse,
			Error.NoRouteToHost             => .NoRouteToHost
		};
	}

	pub fn getResult( self: Errno ) isize {
		return -@intFromEnum( self );
	}

	pub fn format( self: Errno, _: []const u8, _: std.fmt.FormatOptions, writer: anytype ) anyerror!void {
		return std.fmt.format( writer, "{} (task.Error.{s})", .{ self.getResult(), @tagName( self ) } );
	}
};
