/// Type of kernel timestamp.
pub const Ktimestamp = u64;

/// Timer callback ID.
///
/// Used to unregister a callback.
pub const Id = u32;

/// Lock to protect the event list.
var lock: SpinLock = .{};

/// Initialize the timer subsystem.
///
/// Registers the hardware timer interrupt handler and starts the timer.
pub fn init() void {
    urd.exception.setHandler(arch.timer.ppi_intid, timerHandler) catch {
        @panic("Failed to set timer interrupt handler.");
    };

    board.enableIrq(arch.timer.ppi_intid);
    arch.timer.enable();
    //armTimer();
}

/// Register a periodic timer callback.
///
/// The callback will be invoked approximately every `interval_us` microseconds.
/// No guarantee is made about the exact timing, and callbacks may be delayed if the system is busy.
///
/// Returns an ID that can be used to unregister the callback.
pub fn register(interval_us: u64, callback: *const fn () void) Allocator.Error!Id {
    const allocator = urd.mem.getGeneralAllocator();
    const entry = try allocator.create(Entry);
    errdefer allocator.destroy(entry);

    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    entry.* = .{
        .id = allocateId(),
        .interval_us = interval_us,
        .next_us = getCurrentTimestampUs() + interval_us,
        .callback = callback,
    };
    entries.append(entry);

    return entry.id;
}

/// Unregister a previously registered timer callback.
pub fn unregister(id: Id) void {
    const allocator = urd.mem.getGeneralAllocator();
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    var it = entries.iter();
    while (it.next()) |entry| {
        if (entry.id == id) {
            entries.remove(entry);
            allocator.destroy(entry);
            return;
        }
    }
}

/// Get the current kernel timestamp in nanoseconds.
pub fn getCurrentTimestamp() Ktimestamp {
    return arch.timer.getCount() * 1_000_000_000 / arch.timer.getFreq();
}

// =============================================================
// Internal
// =============================================================

/// Timer callback entry.
const Entry = struct {
    /// Unique ID of the timer callback.
    id: Id,
    /// Interval of the timer callback in microseconds.
    interval_us: u64,
    /// Next scheduled time for the timer callback in microseconds.
    next_us: u64,
    /// Callback function to be invoked when the timer expires.
    callback: *const fn () void,
    /// List head.
    head: EntryList.Head = .{},
};

/// List type for timer callback entries.
const EntryList = common.typing.InlineDoublyLinkedList(Entry, "head");
/// List of timer callbacks.
var entries: EntryList = .{};
/// Next unique ID to assign to a timer callback.
var id_next: Id = 1;

/// Base timer tick interval in microseconds.
const tick_interval_us: u64 = 5 * std.time.us_per_ms;

/// Allocate a new unique ID for a timer entries.
fn allocateId() Id {
    const id = id_next;
    id_next +%= 1;
    return id;
}

/// Get the current kernel timestamp in microseconds.
fn getCurrentTimestampUs() Ktimestamp {
    return arch.timer.getCount() * std.time.us_per_s / arch.timer.getFreq();
}

/// Timer interrupt handler.
///
/// Re-arms the timer and dispatches all due callbacks.
fn timerHandler(_: urd.exception.Vector) void {
    armTimer();

    const now_us = getCurrentTimestampUs();
    var it = entries.iter();
    while (it.next()) |entry| {
        if (now_us >= entry.next_us) {
            entry.callback();
            entry.next_us += entry.interval_us;
        }
    }
}

/// Re-arm the timer for the next tick.
fn armTimer() void {
    const ticks = (tick_interval_us * arch.timer.getFreq()) / std.time.us_per_s;
    arch.timer.setDeadline(@intCast(ticks));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const arch = @import("arch").impl;
const board = @import("board").impl;
const common = @import("common");
const urd = @import("urthr");
const SpinLock = urd.SpinLock;
