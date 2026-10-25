/// syscall: mount
pub fn sysMount(
    _: ?[*:0]const u8,
    target: [*:0]const u8,
    filesystem_type: ?[*:0]const u8,
    flags: MountFlags,
    _: ?*const anyopaque,
) ReturnType {
    const allocator = urd.mem.bin;
    var upath: helper.UserPath = .{};
    const path = upath.copyFrom(target) orelse return .err(.fault);

    // For remount, just check if the target path exists and is a mount point.
    if (flags.remount) {
        const resolved = fs.resolve(
            path,
            allocator,
            true,
        ) catch |err| return maperror(err);

        resolved.put();
        return .success(0);
    }

    // Create a new filesystem instance based on the specified filesystem type.
    var fsupath: helper.UserPath = .{};
    const fstype = filesystem_type orelse return .err(.inval);
    const fstype_s = fsupath.copyFrom(fstype) orelse return .err(.fault);
    if (!std.mem.eql(u8, fstype_s, "proc")) {
        return .err(.nodev);
    }
    const new_fs = (fs.ProcFs.init(allocator) catch return .err(.nomem)).filesystem();

    // Mount the new filesystem at the specified target path.
    const resolved = fs.resolve(path, allocator, true) catch |err| return maperror(err);
    defer resolved.put();

    fs.mount(resolved, new_fs, allocator) catch |err| return maperror(err);

    return .success(0);
}

/// syscall: umount2
pub fn sysUmount2(target: [*:0]const u8, flags: UmountFlags) ReturnType {
    const allocator = urd.mem.bin;
    var tbuf: helper.UserPath = .{};
    const s_target = tbuf.copyFrom(target) orelse return .err(.fault);

    if (flags.detach or flags.expire) {
        return .err(.inval);
    }

    const path = fs.resolve(s_target, allocator, !flags.nofollow) catch |err| return maperror(err);
    defer path.put();

    fs.umount(path, allocator) catch |err| return maperror(err);

    return .success(0);
}

const MountFlags = packed struct(u64) {
    /// Mount filesystem read-only.
    rdonly: bool = false,
    /// Do not honor set-user-ID and set-group-ID bits or file capabilities when executing programs from this filesystem.
    nosuid: bool = false,
    /// Do not allow access to devices on this filesystem.
    nodev: bool = false,
    /// Do not allow programs to be executed from this filesystem.
    noexec: bool = false,
    /// Writes are synced immediately.
    synchronous: bool = false,
    /// Remount an existing mount.
    remount: bool = false,
    /// Reserved.
    _6: u2 = 0,
    /// Do not update access times.
    noatime: bool = false,
    /// Do not update directory access times.
    nodiratime: bool = false,
    /// Bind mount.
    bind: bool = false,
    /// Move a subtree.
    move: bool = false,
    /// Reserved.
    _13: u52 = 0,
};

/// Flags for umount2.
const UmountFlags = packed struct(u64) {
    /// Ask the filesystem to abort pending requests before attempting the unmount.
    force: bool = false,
    /// Lazy unmount.
    detach: bool = false,
    /// Mark the mount as expired.
    expire: bool = false,
    /// Do not follow symbolic links.
    nofollow: bool = false,
    /// Reserved.
    _4: u60 = 0,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const fs = urd.fs;
const ReturnType = urd.syscall.ReturnType;

const helper = @import("helper.zig");
const maperror = helper.maperror;
