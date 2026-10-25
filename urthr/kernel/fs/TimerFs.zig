//! Timer filesystem.
//!
//! Anonymous pseudo-filesystem backing timer file descriptors.
//!
//! Not mounted in the VFS tree.

const Self = @This();

/// Memory allocator.
allocator: Allocator,

/// Initialize a timerfd filesystem instance.
pub fn init(allocator: Allocator) error{OutOfMemory}!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
    };

    return self;
}

/// Timer-specific inode implementation.
const InodeImpl = struct {
    /// Common part of the inode.
    common: fs.Inode,

    /// Timer queued while the timerfd is armed.
    timer: Timer = .{
        .deadline_ns = 0,
        .callback = fire,
        .fired = true,
    },
    /// Number of expirations since the last read.
    nexpirations: u64 = 0,
    /// Signaled when the timer has expired.
    event: Event = .{},

    /// Serializes arming and disarming.
    arm_lock: Mutex = .{},
    /// Lock protecting this inode implementation.
    lock: SpinLock = .{},

    /// Memory allocator.
    allocator: Allocator,

    pub fn from(inode: *fs.Inode) *InodeImpl {
        return @fieldParentPtr("common", inode);
    }

    /// Get the current setting of the timer.
    pub fn getSetting(self: *InodeImpl, now: u64) Itimer.Value {
        return if (self.timer.fired)
            .{ .value_ns = 0, .interval_ns = 0 }
        else
            .{
                .value_ns = self.timer.deadline_ns -| now,
                .interval_ns = self.timer.interval_ns,
            };
    }

    /// Consume the number of expirations.
    pub fn take(self: *InodeImpl) u64 {
        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);

        defer self.nexpirations = 0;
        return self.nexpirations;
    }
};

/// Allocate a new timerfd and return its file object.
pub fn createTimer(self: *Self) fs.Error!*fs.File {
    const allocator = self.allocator;

    // Initialize the timer inode.
    const timer = try allocator.create(InodeImpl);
    timer.* = .{
        .common = .{
            .number = 0,
            .size = 0,
            .ftype = .regular,
            .iops = timerfd_iops,
            .fops = undefined,
        },
        .allocator = allocator,
    };

    // The dentry takes over the inode reference only on success.
    const dentry = fs.Dentry.create(
        "",
        &timer.common,
        null,
        allocator,
    ) catch |err| {
        timer.common.unref();
        return err;
    };
    errdefer dentry.unref();

    const file = try allocator.create(fs.File);
    errdefer allocator.destroy(file);
    file.* = .{
        .path = .{ .dentry = dentry, .mount = null },
        .offset = 0,
        .access = .read_only,
        .seekable = false,
        .ops = timerfd_fops,
        .ctx = timer,
        .allocator = allocator,
    };

    return file;
}

/// Arm or disarm the timer.
///
/// Returns the old setting that was replaced.
pub fn setTime(file: *fs.File, new: Itimer.Value) fs.Error!Itimer.Value {
    const timer = from(file) orelse return fs.Error.InvalidArgument;

    timer.arm_lock.lock();
    defer timer.arm_lock.unlock();

    const now = time.getCurrentTimestamp();
    const old = timer.getSetting(now);
    _ = time.cancelTimer(&timer.timer);
    _ = timer.take();

    if (new.value_ns != 0) {
        timer.timer.deadline_ns = now +| new.value_ns;
        timer.timer.interval_ns = new.interval_ns;
        time.scheduleTimer(&timer.timer);
    }

    return old;
}

/// Get the current setting of the timer of the timerfd.
pub fn getTime(file: *fs.File) fs.Error!Itimer.Value {
    const timer = from(file) orelse return fs.Error.InvalidArgument;

    return timer.getSetting(time.getCurrentTimestamp());
}

/// Get the timer inode of the file if it is a timerfd.
fn from(file: *fs.File) ?*InodeImpl {
    return if (file.ops.close == timerfd_fops.close)
        @ptrCast(@alignCast(file.ctx))
    else
        null;
}

/// Record an expiration and wake the waiters.
///
/// Called in IRQ context.
fn fire(timer: *Timer) void {
    const self: *InodeImpl = @fieldParentPtr("timer", timer);

    const ie = self.lock.lockDisableIrq();
    self.nexpirations +|= 1;
    self.lock.unlockRestoreIrq(ie);

    self.event.wakeAll();
}

// =============================================================
// Inode vtable
// =============================================================

const timerfd_iops = fs.Inode.Ops{
    .lookup = &iLookup,
    .deinit = &iDeinit,
};

fn iLookup(_: *fs.Inode, _: []const u8) fs.Error!?*fs.Inode {
    // No FS hierarchy.
    return null;
}

fn iDeinit(inode: *fs.Inode) void {
    const timer = InodeImpl.from(inode);
    timer.allocator.destroy(timer);
}

// =============================================================
// File vtable
// =============================================================

const timerfd_fops = fs.File.Ops{
    .open = &fOpen,
    .iterate = &fIterate,
    .read = &fRead,
    .write = null,
    .close = &fClose,
    .poll = &fPoll,
};

fn fOpen(_: *fs.Inode, _: Allocator) fs.Error!*anyopaque {
    @panic("timerfd: open() must not be called.");
}

fn fIterate(_: *fs.File.Iterator, _: Allocator) fs.Error!?fs.File.IterResult {
    return null;
}

/// Read the number of expirations since the last read.
///
/// Blocks for the next expiration unless at least one expiration is available.
fn fRead(file: *fs.File, buf: []u8, _: usize) fs.Error!usize {
    const T = u64;
    if (buf.len < @sizeOf(T)) {
        return fs.Error.InvalidArgument;
    }

    const timer = from(file).?;
    while (true) {
        const n = timer.take();
        if (n != 0) {
            @memcpy(buf[0..@sizeOf(T)], std.mem.asBytes(&n));
            return @sizeOf(T);
        }
        if (file.status_flags.nonblock) {
            return fs.Error.WouldBlock;
        }
        _ = timer.event.wait(null);
    }
}

fn fClose(ctx: *anyopaque, _: Allocator) void {
    const timer: *InodeImpl = @ptrCast(@alignCast(ctx));
    _ = time.cancelTimer(&timer.timer);
}

fn fPoll(file: *fs.File) fs.Error!fs.PollResult {
    const timer = from(file).?;

    const ie = timer.lock.lockDisableIrq();
    defer timer.lock.unlockRestoreIrq(ie);

    return .{
        .events = .{ .in = timer.nexpirations != 0 },
        .wait = &timer.event,
    };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const urd = @import("urthr");
const fs = urd.fs;
const time = urd.time;
const Event = urd.sync.Event;
const Mutex = urd.sync.Mutex;
const SpinLock = urd.sync.SpinLock;
const Itimer = urd.task.Itimer;
const Timer = time.Timer;
