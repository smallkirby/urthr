//! Devices under /dev filesystem.

// =============================================================
// List of statically registered devices
// =============================================================

const staticdevs = StaticDevices(&.{
    @import("dev/console.zig"),
});

// =============================================================
// API
// =============================================================

/// Initialize devfs.
pub fn init() fs.Error!void {
    const allocator = urd.mem.getGeneralAllocator();
    const cur = sched.getCurrent();
    rtt.expectEqual(0, cur.id);

    // Mount devfs at /dev.
    const devfs = try fs.DevFs.init(allocator);
    const mntpnt = try fs.resolve("/dev", allocator);
    defer mntpnt.dentry.unref();
    try fs.mount(mntpnt, devfs.filesystem(), allocator);

    // Register devices.
    try staticdevs.register(devfs);
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
                try devfs.registerDevice(module.name, module.fops);
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
