pub const Error = error{
    /// Too many backends registered.
    TooManyBackends,
};

/// The number of console backends that can be registered.
const max_backends = 2;

/// Registered console backends.
var backends: [max_backends]?Console = [_]?Console{null} ** max_backends;
/// Lock to protect console module.
var lock: SpinLock = .{};

/// Register a backend. Returns error if all slots are occupied.
pub fn addBackend(c: Console) Error!void {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    for (&backends) |*slot| {
        if (slot.* == null) {
            slot.* = c;
            return;
        }
    } else return Error.TooManyBackends;
}

/// Broadcast a slice to all registered backends.
pub fn write(s: []const u8) void {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    broadcastToBackends(s);
}

/// Broadcast without acquiring the lock.
pub fn writeUnsafe(s: []const u8) void {
    broadcastToBackends(s);
}

/// Run periodic housekeeping on every registered backend.
pub fn tick() void {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    for (&backends) |*slot| {
        if (slot.*) |*b| b.tick();
    }
}

/// Interval to invoke tick callback in microseconds.
const tick_interval_us = 500 * std.time.us_per_ms;

/// Start the console tick timer.
pub fn initTimer() void {
    _ = urd.time.register(tick_interval_us, &tick) catch {
        @panic("Failed to register console tick timer callback.");
    };
}

/// Broadcast a slice to all registered backends.
///
/// Caller must hold the lock.
fn broadcastToBackends(s: []const u8) void {
    for (&backends) |*slot| {
        if (slot.*) |*b| {
            _ = b.print(s);
        }
    }
}

// =============================================================
// Unsafe
// =============================================================

/// Returns a Console that does not acquire the lock before writing.
///
/// This console must be used only in fatal contexts.
pub fn getUnsafeConsole() Console {
    return .{
        .vtable = unsafe_vtable,
        .ctx = @ptrCast(&backends),
    };
}

const unsafe_vtable = Console.Vtable{
    .putc = unsafePutc,
    .flush = unsafeFlush,
};

fn unsafePutc(_: *anyopaque, c: u8) void {
    const buf = [1]u8{c};
    broadcastToBackends(&buf);
}

fn unsafeFlush(_: *anyopaque) void {}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const Console = common.Console;
const urd = @import("urthr");
const SpinLock = urd.sync.SpinLock;
