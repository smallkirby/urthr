/// syscall: sync
pub fn sysSync() ReturnType {
    fs.syncAll() catch |e| return maperror(e);
    return .success(0);
}

/// syscall: fsync
///
/// TODO: fine-grained sync, not FS-wide flush.
pub const sysFsync = sysSyncFs;

/// syscall: fdatasync
///
/// TODO: fine-grained sync, not FS-wide flush.
pub const sysFdataSync = sysSyncFs;

/// syscall: syncfs
///
/// Flush the filesystem that the file belongs to.
pub fn sysSyncFs(fd: i32) ReturnType {
    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();

    fs.syncFsAt(file.path) catch |e| return maperror(e);
    return .success(0);
}

// =============================================================
// Imports
// =============================================================

const urd = @import("urthr");
const fs = urd.fs;
const ReturnType = urd.syscall.ReturnType;

const helper = @import("helper.zig");
const maperror = helper.maperror;
const getFile = helper.getFile;
