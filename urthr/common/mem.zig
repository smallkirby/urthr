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

/// Size in bytes of 4KiB.
pub const size_4kib = 4 * units.kib;
/// Size in bytes of 2MiB.
pub const size_2mib = 2 * units.mib;
/// Size in bytes of 1GiB.
pub const size_1gib = 1 * units.gib;

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

/// Set of memory allocators.
pub const MemoryManager = struct {
    /// General purpose allocator.
    general: std.mem.Allocator,
    /// I/O memory allocator.
    io: IoAllocator,
    /// Page allocator.
    page: PageAllocator,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const units = common.units;
const PageAllocator = @import("PageAllocator.zig");
const IoAllocator = @import("IoAllocator.zig");
