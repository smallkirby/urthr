//! Manages available framebuffers.

pub const Error = error{
    /// Too many backends registered.
    TooManyBackends,
} || urd.fs.Error;

/// The number of framebuffer backends that can be registered.
const max_backends = 3;

/// Registered framebuffer backends.
var backends: [max_backends]?Framebuffer = @splat(null);
/// Lock to protect the registered backends.
var lock: SpinLock = .{};

/// Register a framebuffer backend.
///
/// Returns error if all slots are occupied.
pub fn addBackend(f: Framebuffer) Error!void {
    const index = blk: {
        const ie = lock.lockDisableIrq();
        defer lock.unlockRestoreIrq(ie);

        for (&backends, 0..) |*slot, i| {
            if (slot.* == null) {
                slot.* = f;
                break :blk i;
            }
        } else return Error.TooManyBackends;
    };

    // Expose the framebuffer as /dev/fbN.
    var buf: [8]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "fb{d}", .{index}) catch unreachable;
    try urd.dev.register(name, fbdev.fops, &backends[index].?);
}

/// Get a framebuffer backend by index.
pub fn get(index: usize) ?*Framebuffer {
    if (index >= max_backends) return null;

    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);
    return if (backends[index]) |*backend| backend else null;
}

/// Get the number of registered framebuffer backends.
pub fn count() usize {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    var result: usize = 0;
    for (backends) |backend| {
        if (backend != null) result += 1;
    }
    return result;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const Framebuffer = common.Framebuffer;
const urd = @import("urthr");
const sync = urd.sync;
const SpinLock = sync.SpinLock;
const fbdev = @import("dev/fb.zig");
