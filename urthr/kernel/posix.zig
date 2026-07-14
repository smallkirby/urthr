pub const fs = @import("posix/fs.zig");
pub const mem = @import("posix/mem.zig");
pub const sched = @import("posix/sched.zig");
pub const signal = @import("posix/signal.zig");
pub const system = @import("posix/system.zig");
pub const task = @import("posix/task.zig");
pub const time = @import("posix/time.zig");

/// POSIX-compliant timespec structure.
pub const Timespec = extern struct {
    /// Seconds.
    sec: i64,
    /// Nanoseconds.
    nsec: u32,
};

pub const ErrorEnum = enum(i64) {
    /// Operation not permitted.
    perm = -1,
    /// No such file or directory.
    noent = -2,
    /// No child processes.
    child = -10,
    /// Too large.
    toobig = -7,
    /// Exec format error.
    noexec = -8,
    /// Bad file descriptor.
    badf = -9,
    /// Resource temporarily unavailable.
    again = -11,
    /// Cannot allocate memory.
    nomem = -12,
    /// Permission denied.
    nacces = -13,
    /// File exists.
    exist = -17,
    /// Not a directory.
    notdir = -20,
    /// Is a directory.
    isdir = -21,
    /// Invalid argument.
    inval = -22,
    /// Too many open files.
    mfile = -24,
    /// Not a TTY.
    notty = -25,
    /// Broken pipe.
    pipe = -32,
    /// Result too large.
    range = -34,
    /// Function not implemented.
    nosys = -38,
};
