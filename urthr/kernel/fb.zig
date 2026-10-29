//! Manages available framebuffers.

pub const Error = error{
    /// Too many backends registered.
    TooManyBackends,
} || urd.fs.Error;

/// Registered framebuffer backend.
pub const Backend = struct {
    /// Framebuffer.
    fb: Framebuffer,
    /// Whether the framebuffer contains dirty data.
    dirty: std.atomic.Value(bool) = .init(false),
};

/// The number of framebuffer backends that can be registered.
const max_backends = 3;
/// Interval in microseconds to flush dirty framebuffers.
const flush_interval_us = 16 * std.time.us_per_ms;

/// Registered framebuffer backends.
var backends: [max_backends]?Backend = @splat(null);
/// Lock to protect the registered backends.
var lock: SpinLock = .{};

/// Start the worker thread that flushes dirty framebuffers.
///
/// Must be called after the scheduler is started.
pub fn init() urd.task.Error!void {
    _ = try urd.task.kspawn("fb-flusher", flushWorker, .{});
}

/// Register a framebuffer backend.
///
/// Returns error if all slots are occupied.
pub fn addBackend(f: Framebuffer) Error!void {
    const index = blk: {
        const ie = lock.lockDisableIrq();
        defer lock.unlockRestoreIrq(ie);

        for (&backends, 0..) |*slot, i| {
            if (slot.* == null) {
                slot.* = .{ .fb = f };
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
pub fn get(index: usize) ?*Backend {
    if (index >= max_backends) return null;

    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);
    return if (backends[index]) |*backend| backend else null;
}

/// Mark the framebuffer as dirty.
///
/// The framebuffer is flushed later by the flusher worker.
pub fn markDirty(backend: *Backend) void {
    backend.dirty.store(true, .release);
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

/// Thread function that periodically flushes dirty framebuffers.
fn flushWorker() noreturn {
    while (true) {
        urd.time.sleepUs(flush_interval_us);

        for (0..max_backends) |i| {
            if (get(i)) |backend| {
                if (backend.dirty.swap(false, .acq_rel)) {
                    backend.fb.flush();
                }
            }
        }
    }
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
