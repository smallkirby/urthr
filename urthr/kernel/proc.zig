var procfs: *ProcFs = undefined;

/// Initialize procfs.
pub fn init(allocator: Allocator) fs.Error!void {
    // Create procfs instance.
    procfs = try ProcFs.init(allocator);

    // Mount procfs to /proc.
    const mntpnt = try fs.resolve("/proc", allocator);
    defer mntpnt.dentry.unref();
    try fs.mount(mntpnt, procfs.filesystem(), allocator);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const urd = @import("urthr");
const fs = urd.fs;
const ProcFs = fs.ProcFs;
