//! Devices under /dev filesystem.

// =============================================================
// List of statically registered devices
// =============================================================

const staticdevs = StaticDevices(&.{
    @import("dev/console.zig"),
    @import("dev/null.zig"),
    @import("dev/tty.zig"),
    @import("dev/zero.zig"),
});

// =============================================================
// API
// =============================================================

/// Devfs instance.
var instance: *fs.DevFs = undefined;

/// Create devfs and register static devices.
///
/// The filesystem is not visible until mounted.
pub fn create() fs.Error!void {
    const devfs = try fs.DevFs.init(urd.mem.bin);
    try staticdevs.register(devfs);
    instance = devfs;
}

/// Mount devfs at /dev.
pub fn mount() fs.Error!void {
    const allocator = urd.mem.bin;
    const cur = sched.getCurrent();
    rtt.expectEqual(1, cur.id);

    const mntpnt = try fs.resolve("/dev", allocator, true);
    defer mntpnt.put();
    try fs.mount(mntpnt, instance.filesystem(), allocator);
}

/// Register a device under /dev.
pub fn register(name: []const u8, fops: fs.File.Ops, ctx: ?*anyopaque) fs.Error!void {
    return instance.registerDevice(name, fops, ctx);
}

// =============================================================
// Static device registration
// =============================================================

const Module = struct {
    name: []const u8,
    fops: fs.File.Ops,
};

fn StaticDevices(comptime devices: []const type) type {
    return struct {
        const Self = @This();

        const modules = blk: {
            var list: [devices.len]Module = undefined;
            for (devices, 0..) |dev, i| {
                list[i] = .{
                    .name = dev.name,
                    .fops = dev.fops,
                };
            }

            break :blk list;
        };

        pub fn register(devfs: *fs.DevFs) fs.Error!void {
            for (modules) |module| {
                try devfs.registerDevice(module.name, module.fops, null);
            }
        }
    };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const fs = urd.fs;
const sched = @import("sched.zig");
