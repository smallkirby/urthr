//! Performance trace event recorder.

/// Path of the dump file on the mounted root filesystem.
pub const dump_path = "/PERFLOG";

/// Number of records currently held in the given core's buffer.
pub fn len(core: usize) usize {
    const c = &cores[core];
    const ie = c.lock.lockDisableIrq();
    defer c.lock.unlockRestoreIrq(ie);
    return c.count;
}

/// Get the i-th oldest record currently in the given core's buffer.
pub fn at(core: usize, i: usize) Record {
    const c = &cores[core];
    const ie = c.lock.lockDisableIrq();
    defer c.lock.unlockRestoreIrq(ie);

    rtt.expect(i < c.count);
    const oldest = (c.head + buffer_len - c.count) % buffer_len;
    return c.buffer[(oldest + i) % buffer_len];
}

/// Record an event with the current timestamp and thread ID.
pub fn record(payload: EventPayload) void {
    if (!options.enable_perf) return;

    const timestamp_ns: u64 = @intCast((@as(u128, arch.timer.getCount()) * std.time.ns_per_s) / arch.timer.getFreq());
    const tid = urd.sched.getCurrent().id;
    const core = urd.smp.getLogicalCoreId();
    const c = &cores[core];

    const ie = c.lock.lockDisableIrq();
    defer c.lock.unlockRestoreIrq(ie);

    c.buffer[c.head] = .{
        .timestamp_ns = timestamp_ns,
        .tid = tid,
        .core = @intCast(core),
        .payload = payload,
    };
    c.head = (c.head + 1) % buffer_len;
    if (c.count < buffer_len) c.count += 1;
}

/// Record the name of the current thread.
pub fn recordThreadName(name: []const u8) void {
    var buf: [perf.ThreadName.max_len]u8 = @splat(0);
    const n = @min(name.len, buf.len);
    @memcpy(buf[0..n], name[0..n]);
    record(.init(.thread_name, .{ .name = buf }));
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

    var cursors = [_]usize{0} ** board.num_cpus;
    var lens: [board.num_cpus]usize = undefined;
    for (0..board.num_cpus) |core| lens[core] = len(core);

    var wbuf: [256]Record = undefined;
    var wlen: usize = 0;

    while (true) {
        // Select the oldest record among all cores' buffers.
        const core = blk: {
            var pick: ?usize = null;
            var pick_ts: u64 = undefined;
            for (0..board.num_cpus) |c| {
                if (cursors[c] >= lens[c]) continue;

                const ts = at(c, cursors[c]).timestamp_ns;
                if (pick == null or ts < pick_ts) {
                    pick = c;
                    pick_ts = ts;
                }
            }
            break :blk pick orelse break;
        };

        // Push the record into the buffer.
        wbuf[wlen] = at(core, cursors[core]);
        wlen += 1;
        cursors[core] += 1;

        // Flush the buffered records.
        if (wlen == wbuf.len) {
            _ = try file.write(std.mem.sliceAsBytes(wbuf[0..wlen]));
            wlen = 0;
        }
    }

    // Flush remaining records in the buffer.
    if (wlen > 0) {
        _ = try file.write(std.mem.sliceAsBytes(wbuf[0..wlen]));
    }
}

// =============================================================
// Internals
// =============================================================

/// Number of records each core's ring buffer can hold.
const buffer_len: usize = 8192;

/// Per-core ring buffer of recorded events.
const CoreBuffer = struct {
    buffer: [buffer_len]Record = undefined,
    /// Index of the next slot to write.
    head: usize = 0,
    /// Number of valid records in the buffer.
    count: usize = 0,
    /// Protects this core's buffer.
    lock: SpinLock = .{},
};

var cores: [board.num_cpus]CoreBuffer = @splat(.{});

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const options = @import("options");
const arch = @import("arch").impl;
const board = @import("board").impl;
const urd = @import("urthr");
const common = @import("common");
const rtt = common.rtt;
const perf = common.perf;
const Record = perf.Record;
const EventPayload = perf.EventPayload;
const SpinLock = urd.sync.SpinLock;
const fs = urd.fs;
