//! Devices under /dev filesystem.

const console = @import("dev/console.zig");

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
    try devfs.registerDevice("console", console.file_ops);
}

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const fs = urd.fs;
const sched = @import("sched.zig");
