// =============================================================
// fcntl

/// syscall: fcntl
pub fn sysFcntl(fd: i32, op: FcntlOp, arg: u64) ReturnType {
    const cur = sched.getCurrent();

    switch (op) {
        .dupfd, .dupfd_cloexec => {
            const file = getFile(fd) orelse return .err(.badf);
            defer file.unref();

            const flags = FdFlags{ .cloexec = op == .dupfd_cloexec };
            const newfd = cur.fs.fdtbl.allocAt(
                @intCast(arg),
                file,
                flags,
            ) catch |err| {
                return switch (err) {
                    error.TableFull => .err(.mfile),
                    error.InvalidFd => .err(.inval),
                    else => .err(.badf),
                };
            };

            return .success(@intCast(newfd));
        },

        .getfd => {
            const fdidx = fdindex(fd) orelse return .err(.badf);
            const flags = cur.fs.fdtbl.getFlags(fdidx) catch return .err(.badf);
            return .success(@intCast(@as(u32, @bitCast(flags))));
        },
        .setfd => {
            const flags: FdFlags = @bitCast(@as(u32, @truncate(arg)));
            if (flags._reserved != 0) return .err(.inval);

            const fdidx = fdindex(fd) orelse return .err(.badf);
            cur.fs.fdtbl.setFlags(fdidx, flags) catch return .err(.badf);
            return .success(0);
        },

        .getfl => {
            const file = getFile(fd) orelse return .err(.badf);
            defer file.unref();

            const flags = OpenFlags{
                .wo = file.access.writable and !file.access.readable,
                .rdwr = file.access.writable and file.access.readable,
                .nonblock = file.status_flags.nonblock,
                .append = file.status_flags.append,
            };
            return .success(@intCast(@as(i32, @bitCast(flags))));
        },
        .setfl => {
            const file = getFile(fd) orelse return .err(.badf);
            defer file.unref();

            const flags: OpenFlags = @bitCast(@as(u32, @truncate(arg)));
            file.status_flags.set(.{
                .nonblock = flags.nonblock,
                .append = flags.append,
            });
            return .success(0);
        },

        _ => return .err(.inval),
    }
}

/// File control operations.
const FcntlOp = enum(i32) {
    /// Duplicate the file descriptor fd using the lowest-numbered available fd greater than or equal to arg.
    dupfd = 0,
    /// Returns the file descriptor flags.
    getfd = 1,
    /// Set the file descriptor flags specified by arg.
    setfd = 2,
    /// Returns the file access mode and the file status flags.
    getfl = 3,
    /// Set the file status flags to the value specified by arg.
    setfl = 4,
    /// Same as dupfd, but set the close-on-exec flag on the duplicated descriptor.
    dupfd_cloexec = 1030,

    _,
};

// =============================================================
// ioctl

/// syscall: ioctl
pub fn sysIoctl(fd: i32, request: u64, arg: usize) ReturnType {
    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();

    const result = file.ioctl(
        request,
        arg,
    ) catch |err| return switch (err) {
        error.Unsupported => .err(.notty),
        else => {
            log.warn("ioctl(0x{X}) failed: {}", .{ request, err });
            return maperror(err);
        },
    };
    return .success(@intCast(result));
}

// =============================================================
// lock

/// syscall: flock
pub fn sysFlock(fd: i32, op: FlockOp) ReturnType {
    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();

    const user_lock = &file.path.dentry.getInode().user_lock;
    const ltype: SharedLock.LockType = switch (op.value()) {
        .lock_shared => .shared,
        .lock_exclusive => .exclusive,
        .unlock => {
            file.flock.unlock(user_lock);
            return .success(0);
        },
        _ => return .err(.inval),
    };

    if (!op.isNonBlock()) {
        file.flock.lock(user_lock, ltype);
        return .success(0);
    }

    return if (file.flock.tryLock(user_lock, ltype))
        .success(0)
    else
        .err(.again);
}

/// Operations of flock.
const FlockOp = enum(i32) {
    /// Acquire shared lock.
    lock_shared = 1,
    /// Acquire exclusive lock.
    lock_exclusive = 2,
    /// Release the lock.
    unlock = 8,

    _,

    /// Don't block when acquiring the lock.
    const non_block: i32 = 4;

    fn value(self: FlockOp) FlockOp {
        return @fromBackingInt(@backingInt(self) & ~non_block);
    }

    fn isNonBlock(self: FlockOp) bool {
        return (@backingInt(self) & non_block) != 0;
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.pxfs);
const urd = @import("urthr");
const fs = urd.fs;
const sched = urd.sched;
const SharedLock = urd.sync.SharedLock;
const FdFlags = fs.FdTable.FdFlags;
const ReturnType = urd.syscall.ReturnType;

const abi = @import("abi.zig");
const helper = @import("helper.zig");
const OpenFlags = abi.OpenFlags;
const maperror = helper.maperror;
const getFile = helper.getFile;
const fdindex = helper.fdindex;
