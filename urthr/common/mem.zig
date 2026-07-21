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

pub const DmaAllocator = @import("mem/DmaAllocator.zig");
pub const IoAllocator = @import("mem/IoAllocator.zig");
pub const PageAllocator = @import("mem/PageAllocator.zig");

/// Size in bytes of 4KiB.
pub const size_4kib = 4 * units.kib;
/// Size in bytes of 2MiB.
pub const size_2mib = 2 * units.mib;
/// Size in bytes of 1GiB.
pub const size_1gib = 1 * units.gib;

/// Kind of memory access.
pub const AccessType = enum {
    /// Read access.
    read,
    /// Write access.
    write,
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

    pub const rw = Permission{
        .ur = true,
        .uw = true,
        .ux = false,
        .kr = true,
        .kw = true,
        .kx = false,
    };

    pub const kernel_rw = Permission{
        .ur = false,
        .uw = false,
        .ux = false,
        .kr = true,
        .kw = true,
        .kx = false,
    };

    pub const ro = Permission{
        .ur = true,
        .uw = false,
        .ux = false,
        .kr = true,
        .kw = false,
        .kx = false,
    };

    pub const user_ro = Permission{
        .ur = true,
        .uw = false,
        .ux = false,
        .kr = false,
        .kw = false,
        .kx = false,
    };

    pub const none = Permission{
        .ur = false,
        .uw = false,
        .ux = false,
        .kr = false,
        .kw = false,
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
    /// Normal memory, but write combining is allowed.
    ///
    /// The memory is non-cacheable, but write combining is allowed.
    wc,
    /// Normal memory, non-cacheable.
    nc,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const units = common.units;
