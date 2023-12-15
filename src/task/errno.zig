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
	InvalidArgument,
	NotImplemented,
	NotSocket,
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
	/// EINVAL
	InvalidArgument           = 22,
	/// ENOSYS
	NotImplemented            = 38,
	/// ENOTSOCK
	NotSocket                 = 88,
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
			Error.InvalidArgument           => .InvalidArgument,
			Error.NotImplemented            => .NotImplemented,
			Error.NotSocket                 => .NotSocket,
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
