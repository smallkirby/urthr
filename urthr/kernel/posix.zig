pub const fs = @import("posix/fs.zig");
pub const sched = @import("posix/sched.zig");
pub const signal = @import("posix/signal.zig");
pub const task = @import("posix/task.zig");

pub const ErrorEnum = enum(i64) {
    /// Bad file descriptor.
    badf = -9,
    /// Resource temporarily unavailable.
    again = -11,
    /// Cannot allocate memory.
    nomem = -12,
    /// Invalid argument.
    inval = -22,
    /// Not a TTY.
    notty = -25,
    /// Function not implemented.
    nosys = -38,
};
