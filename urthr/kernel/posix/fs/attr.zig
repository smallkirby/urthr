// =============================================================
// chmod

/// syscall: fchmodat
pub fn sysFchmodAt(dirfd: i32, pathname: [*:0]const u8, mode: Mode) ReturnType {
    var upath: helper.UserPath = .{};
    const path = upath.copyFrom(pathname) orelse return .err(.fault);

    const file = openFileAt(
        dirfd,
        path,
        .{},
        urd.mem.bin,
        true,
    ) catch |err| return maperror(err);
    defer file.unref();

    file.chmod(mode.to()) catch |err| return maperror(err);

    return .success(0);
}

/// syscall: chmod
pub fn sysChmod(pathname: [*:0]const u8, mode: Mode) ReturnType {
    return sysFchmodAt(helper.cwd_fd, pathname, mode);
}

/// syscall: fchmod
pub fn sysFchmod(fd: i32, mode: Mode) ReturnType {
    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();

    file.chmod(mode.to()) catch |err| return maperror(err);

    return .success(0);
}

// =============================================================
// chown

/// syscall: fchown
pub fn sysFchown(fd: i32, uid: u32, gid: u32) ReturnType {
    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();

    file.chown(
        idOptional(uid),
        idOptional(gid),
    ) catch |err| return maperror(err);

    return .success(0);
}

/// syscall: fchownat
pub fn sysFchownAt(
    dirfd: i32,
    pathname: [*:0]const u8,
    uid: u32,
    gid: u32,
    flags: AtFlags,
) ReturnType {
    if (!flags.isFit(.{ .symlink_nofollow = true, .empty_path = true })) {
        return .err(.inval);
    }

    // Resolve the target path.
    const resolved = ResolveFile.atUser(
        dirfd,
        pathname,
        flags,
        urd.mem.bin,
    ) catch |err| return maperror(err);
    defer resolved.deinit();

    // Perform change of ownership.
    resolved.file.chown(
        idOptional(uid),
        idOptional(gid),
    ) catch |err| return maperror(err);

    return .success(0);
}

/// syscall: chown
pub fn sysChown(pathname: [*:0]const u8, uid: u32, gid: u32) ReturnType {
    return sysFchownAt(helper.cwd_fd, pathname, uid, gid, .{});
}

/// syscall: lchown
pub fn sysLchown(pathname: [*:0]const u8, uid: u32, gid: u32) ReturnType {
    return sysFchownAt(helper.cwd_fd, pathname, uid, gid, .{
        .symlink_nofollow = true,
    });
}

/// Convert an UID or GID processing special ID values.
fn idOptional(id: u32) ?u32 {
    const keep_id: u32 = std.math.maxInt(u32); // keep the ID unchanged.
    return if (id == keep_id) null else id;
}

// =============================================================
// access

/// syscall: faccessat
pub fn sysFaccessAt(dirfd: i32, pathname: [*:0]const u8, mode: AccessFlags) ReturnType {
    if (mode._reserved != 0) {
        return .err(.inval);
    }

    var upath: helper.UserPath = .{};
    const path = upath.copyFrom(pathname) orelse return .err(.fault);

    // TODO: perform access check.
    const file = openFileAt(
        dirfd,
        path,
        .{},
        urd.mem.bin,
        true,
    ) catch |err| return maperror(err);
    file.unref();

    return .success(0);
}

/// syscall: access
pub fn sysAccess(pathname: [*:0]const u8, mode: AccessFlags) ReturnType {
    return sysFaccessAt(helper.cwd_fd, pathname, mode);
}

/// Access mode flags to check.
const AccessFlags = packed struct(i32) {
    /// Execute permission.
    exec: bool = false,
    /// Write permission.
    write: bool = false,
    /// Read permission.
    read: bool = false,
    /// Reserved.
    _reserved: u29 = 0,
};

// =============================================================
// utime

/// syscall: utimensat
pub fn sysUtimensAt(
    dirfd: i32,
    pathname: ?[*:0]const u8,
    times: ?*align(1) const [2]Timespec,
    flags: AtFlags,
) ReturnType {
    if (!flags.isFit(.{ .symlink_nofollow = true })) {
        return .err(.inval);
    }

    // Resolve the requested times.
    const now = fs.Timestamp.now();
    var atime: ?fs.Timestamp = now;
    var mtime: ?fs.Timestamp = now;
    if (times) |t| {
        const tv = urd.uaccess.getUser(
            [2]Timespec,
            t,
        ) catch return .err(.fault);
        atime = resolveUtime(tv[0], now) catch return .err(.inval);
        mtime = resolveUtime(tv[1], now) catch return .err(.inval);
    }

    var ubuf: helper.UserPath = .{};
    const path: ?[]const u8 = if (pathname) |p|
        ubuf.copyFrom(p) orelse return .err(.fault)
    else
        null;

    // Resolve the target file.
    const file = if (path) |p| blk: {
        break :blk openFileAt(
            dirfd,
            p,
            .{},
            urd.mem.bin,
            true,
        ) catch |err| {
            return maperror(err);
        };
    } else blk: {
        break :blk getFile(dirfd) orelse {
            return .err(.badf);
        };
    };
    defer file.unref();

    // Nothing to do if both fields are UTIME_OMIT.
    if (atime == null and mtime == null) {
        return .success(0);
    }

    // Update the timestamps.
    const inode = file.path.dentry.getInode();
    inode.utimes(atime, mtime) catch |err| {
        return maperror(err);
    };

    return .success(0);
}

/// Resolve timespec into a target timestamp.
///
/// Returns null when the field must be left unchanged.
fn resolveUtime(ts: Timespec, now: fs.Timestamp) !?fs.Timestamp {
    // Value requesting the current time.
    const utime_now: i64 = (1 << 30) - 1;
    // Value requesting the timestamp to be left unchanged.
    const utime_omit: i64 = (1 << 30) - 2;

    return switch (ts.nsec) {
        utime_omit => null,
        utime_now => now,
        else => try .from(ts.sec, ts.nsec),
    };
}

// =============================================================
// umask

/// syscall: umask
pub fn sysUmask(mask: Mode) ReturnType {
    const cur = sched.getCurrent();
    const old = cur.fs.info.umask;

    // Update umask of the current thread.
    var value = mask;
    value.flags = .none; // discard other than permission bits
    cur.fs.info.umask = value.to();

    const ret: u32 = @bitCast(Mode.fromFileMode(old));
    return .success(@intCast(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const fs = urd.fs;
const sched = urd.sched;
const ReturnType = urd.syscall.ReturnType;
const Timespec = urd.posix.Timespec;

const abi = @import("abi.zig");
const helper = @import("helper.zig");
const AtFlags = abi.AtFlags;
const Mode = abi.Mode;
const ResolveFile = helper.ResolveFile;
const maperror = helper.maperror;
const getFile = helper.getFile;
const openFileAt = helper.openFileAt;
