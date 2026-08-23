//! Performance trace event recorder.

/// Path of the dump file on the mounted root filesystem.
pub const dump_path = "/PERFLOG";

/// Number of records currently held in the buffer.
pub fn len() usize {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);
    return count;
}

/// Get the i-th oldest record currently in the buffer.
pub fn at(i: usize) Record {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    rtt.expect(i < count);
    const oldest = (head + buffer_len - count) % buffer_len;
    return buffer[(oldest + i) % buffer_len];
}

/// Record an event with the current timestamp and thread ID.
pub fn record(payload: EventPayload) void {
    if (!options.enable_perf) return;

    const timestamp_ns: u64 = @intCast((@as(u128, arch.timer.getCount()) * std.time.ns_per_s) / arch.timer.getFreq());
    const tid = urd.sched.getCurrent().id;

    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    buffer[head] = .{
        .timestamp_ns = timestamp_ns,
        .tid = tid,
        .payload = payload,
    };
    head = (head + 1) % buffer_len;
    if (count < buffer_len) count += 1;
}

/// Write the buffered records to a file mounted on the root filesystem.
pub fn dump() fs.Error!void {
    const allocator = urd.mem.bin;

    const file = fs.open(
        dump_path,
        .write_only,
        allocator,
    ) catch |err| switch (err) {
        fs.Error.NotFound => try fs.create(
            dump_path,
            .{ .user = .rw },
            .write_only,
            allocator,
        ),
        else => return err,
    };
    defer file.unref();

    file.truncate(0) catch |err| switch (err) {
        fs.Error.Unsupported => {},
        else => return err,
    };

    const n = len();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rec = at(i);
        _ = try file.write(std.mem.asBytes(&rec));
    }
}

// =============================================================
// Internals
// =============================================================

/// Number of records the ring buffer can hold.
const buffer_len: usize = 8192;

var buffer: [buffer_len]Record = undefined;
/// Index of the next slot to write.
var head: usize = 0;
/// Number of valid records in the buffer.
var count: usize = 0;
/// Protects buffers.
var lock: SpinLock = .{};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const options = @import("options");
const arch = @import("arch").impl;
const urd = @import("urthr");
const common = @import("common");
const rtt = common.rtt;
const perf = common.perf;
const Event = perf.Event;
const Record = perf.Record;
const EventPayload = perf.EventPayload;
const SpinLock = urd.sync.SpinLock;
const fs = urd.fs;
