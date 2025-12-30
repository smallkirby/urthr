pub const Error = error{
    /// Out of memory.
    OutOfMemory,
    /// Virtual memory allocation failed.
    OutOfVirtualMemory,
    /// The argument is invalid.
    InvalidArgument,
    /// Current mapping does not match the requested mapping.
    InvalidMapping,
    /// The specified region is invalid.
    InvalidRegion,
    /// Resource not available.
    NotAvailable,
};

/// Memory permission.
pub const Permission = struct {
    /// User readable.
    ur: bool,
    /// User writable.
    uw: bool,
    /// User executable.
    ux: bool,
    /// Kernel readable.
    kr: bool,
    /// Kernel writable.
    kw: bool,
    /// Kernel executable.
    kx: bool,

    pub const kernel_rwx = Permission{
        .ur = false,
        .uw = false,
        .ux = false,
        .kr = true,
        .kw = true,
        .kx = true,
    };

    pub const kernel_rw = Permission{
        .ur = false,
        .uw = false,
        .ux = false,
        .kr = true,
        .kw = true,
        .kx = false,
    };
};

/// Memory attribute.
pub const Attribute = enum {
    /// Device memory.
    ///
    /// The memory must be strongly ordered and non-cacheable.
    device,
    /// Normal memory.
    ///
    /// The memory is cacheable.
    normal,
};
