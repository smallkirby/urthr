/// syscall: uname
pub fn sysUname(buf: *UtsName) ReturnType {
    std.mem.copyForwards(u8, &buf.sysname, "Urthr");
    std.mem.copyForwards(u8, &buf.nodename, "");
    std.mem.copyForwards(u8, &buf.release, urd.version);
    std.mem.copyForwards(u8, &buf.version, urd.version);
    std.mem.copyForwards(u8, &buf.machine, @tagName(builtin.cpu.arch));

    return .success(0);
}

const UtsName = struct {
    /// Operating system name.
    sysname: [65]u8,
    /// Name within communications network to which the node is attached if any.
    nodename: [65]u8,
    /// Operating system release.
    release: [65]u8,
    /// Operating system version.
    version: [65]u8,
    /// Hardware type ID.
    machine: [65]u8,
};

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const common = @import("common");
const urd = @import("urthr");
const sched = urd.sched;
const task = urd.task;
const ReturnType = urd.syscall.ReturnType;
