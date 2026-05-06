pub const fs = @import("posix/fs.zig");

pub const ErrorEnum = enum(i64) {
    /// Bad file descriptor.
    badf = -9,
    /// Resource temporarily unavailable.
    again = -11,
    /// Function not implemented.
    nosys = -38,
};
