// =============================================================
// remove

/// syscall: unlinkat
pub fn sysUnlinkAt(dirfd: i32, pathname: [*:0]const u8, flags: AtFlags) ReturnType {
    if (!flags.isFit(.{ .removedir = true })) {
        return .err(.inval);
    }

    var upath: helper.UserPath = .{};
    const path = upath.copyFrom(pathname) orelse return .err(.fault);

    const result = if (flags.removedir)
        rmdirFileAt(dirfd, path, urd.mem.bin)
    else
        unlinkFileAt(dirfd, path, urd.mem.bin);

    return if (result) |_| .success(0) else |err| maperror(err);
}

/// syscall: unlink
pub fn sysUnlink(pathname: [*:0]const u8) ReturnType {
    return sysUnlinkAt(helper.cwd_fd, pathname, .{});
}

/// syscall: rmdir
pub fn sysRmdir(pathname: [*:0]const u8) ReturnType {
    return sysUnlinkAt(helper.cwd_fd, pathname, .{
        .removedir = true,
    });
}

// =============================================================
// symlink

/// syscall: symlinkat
pub fn sysSymlinkAt(
    target: [*:0]const u8,
    newdirfd: i32,
    linkpath: [*:0]const u8,
) ReturnType {
    var tupath: helper.UserPath = .{};
    var lupath: helper.UserPath = .{};
    const path = tupath.copyFrom(target) orelse return .err(.fault);
    const link = lupath.copyFrom(linkpath) orelse return .err(.fault);

    symlinkFileAt(
        newdirfd,
        link,
        path,
        urd.mem.bin,
    ) catch |err| return maperror(err);

    return .success(0);
}

/// syscall: symlink
pub fn sysSymlink(target: [*:0]const u8, linkpath: [*:0]const u8) ReturnType {
    return sysSymlinkAt(target, helper.cwd_fd, linkpath);
}

/// syscall: readlinkat
pub fn sysReadLinkAt(
    dirfd: i32,
    pathname: [*:0]const u8,
    buf: usize,
    bufsize: usize,
) ReturnType {
    if (bufsize == 0) {
        return .err(.inval);
    }

    var upath: helper.UserPath = .{};
    const path = upath.copyFrom(pathname) orelse return .err(.fault);

    var kbuf: [helper.path_max]u8 = undefined;
    const n = readlinkFileAt(
        dirfd,
        path,
        &kbuf,
        urd.mem.bin,
    ) catch |err| return maperror(err);

    const copy_len = @min(n, bufsize);
    uaccess.copyToUser(buf, kbuf[0..copy_len]) catch return .err(.fault);

    return .success(@bitCast(copy_len));
}

/// syscall: readlink
pub fn sysReadLink(pathname: [*:0]const u8, buf: usize, bufsiz: usize) ReturnType {
    return sysReadLinkAt(helper.cwd_fd, pathname, buf, bufsiz);
}

// =============================================================
// rename

/// syscall: renameat
pub fn sysRenameAt(
    olddirfd: i32,
    oldpath: [*:0]const u8,
    newdirfd: i32,
    newpath: [*:0]const u8,
) ReturnType {
    return renameImpl(
        olddirfd,
        oldpath,
        newdirfd,
        newpath,
        false,
    );
}

/// syscall: rename
pub fn sysRename(oldpath: [*:0]const u8, newpath: [*:0]const u8) ReturnType {
    return renameImpl(
        helper.cwd_fd,
        oldpath,
        helper.cwd_fd,
        newpath,
        false,
    );
}

/// syscall: renameat2
pub fn sysRenameAt2(
    olddirfd: i32,
    oldpath: [*:0]const u8,
    newdirfd: i32,
    newpath: [*:0]const u8,
    flags: RenameFlags,
) ReturnType {
    if (flags._reserved != 0 or flags.exchange or flags.whiteout) {
        return .err(.inval);
    }

    return renameImpl(
        olddirfd,
        oldpath,
        newdirfd,
        newpath,
        flags.noreplace,
    );
}

/// Shared implementation of rename family.
fn renameImpl(
    olddirfd: i32,
    oldpath: [*:0]const u8,
    newdirfd: i32,
    newpath: [*:0]const u8,
    noreplace: bool,
) ReturnType {
    var oupath: helper.UserPath = .{};
    var nupath: helper.UserPath = .{};
    const olds = oupath.copyFrom(oldpath) orelse return .err(.fault);
    const news = nupath.copyFrom(newpath) orelse return .err(.fault);

    renameFileAt(
        olddirfd,
        olds,
        newdirfd,
        news,
        noreplace,
        urd.mem.bin,
    ) catch |err| return maperror(err);

    return .success(0);
}

/// Flags for `renameat2`.
const RenameFlags = packed struct(u32) {
    /// Don't overwrite the destination.
    noreplace: bool = false,
    /// Atomically exchange the source and destination.
    exchange: bool = false,
    /// Create a whiteout object at the source of the rename.
    whiteout: bool = false,
    /// Reserved.
    _reserved: u29 = 0,
};

// =============================================================
// Imports
// =============================================================

const urd = @import("urthr");
const uaccess = urd.uaccess;
const ReturnType = urd.syscall.ReturnType;

const abi = @import("abi.zig");
const helper = @import("helper.zig");
const AtFlags = abi.AtFlags;
const maperror = helper.maperror;
const symlinkFileAt = helper.symlinkFileAt;
const readlinkFileAt = helper.readlinkFileAt;
const unlinkFileAt = helper.unlinkFileAt;
const rmdirFileAt = helper.rmdirFileAt;
const renameFileAt = helper.renameFileAt;
