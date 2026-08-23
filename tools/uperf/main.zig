//! uperf: Convert a raw kernel performance trace dump into a Perfetto-loadable JSON file.
//!
//! cf. https://perfetto.dev/docs/getting-started/other-formats

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    defer thread_names.deinit();

    if (args.len != 1 + 2) {
        log.err("Usage: {s} <input> <output.json>", .{args[0]});
        return error.InvalidArgs;
    }

    const input_path = args[1];
    const output_path = args[2];

    var cwd_buf: [128]u8 = undefined;
    const cwd_path = cwd_buf[0..try std.process.currentPath(io, &cwd_buf)];
    const cwd = try std.Io.Dir.openDirAbsolute(io, cwd_path, .{});
    defer cwd.close(io);

    const input_file = try cwd.openFile(io, input_path, .{});
    defer input_file.close(io);

    // Read the entire input.
    var rbuf: [4096]u8 = undefined;
    var input_reader = input_file.reader(io, &rbuf);
    const input_bytes = try input_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(input_bytes);

    if (input_bytes.len % @sizeOf(perf.Record) != 0) {
        log.err(
            "Input size {d} is not a multiple of record size {d}",
            .{ input_bytes.len, @sizeOf(perf.Record) },
        );
        return error.InvalidInput;
    }

    // Parse the input as a slice of records.
    const records = std.mem.bytesAsSlice(perf.Record, input_bytes);

    const output_file = try cwd.createFile(io, output_path, .{});
    defer output_file.close(io);

    var wbuf: [4096]u8 = undefined;
    var output_writer = output_file.writer(io, &wbuf);
    const w = &output_writer.interface;

    // Find the maximum core ID and timestamp.
    var max_core: u32 = 0;
    var max_ts: u64 = 0;
    for (records) |rec| {
        max_core = @max(max_core, rec.core);
        max_ts = @max(max_ts, rec.timestamp_ns);
    }
    cpu_pid_base = max_core + 1;

    // Start conversion.
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginArray();

    // Record core names and their scheduling processes.
    // Using process name metadata events for this purpose.
    var core: u32 = 0;
    while (core <= max_core) : (core += 1) {
        var name_buf: [16]u8 = undefined;

        // Record core name.
        try s.write(CoreNameEvent{
            .pid = core,
            .args = .{ .name = try std.fmt.bufPrint(
                &name_buf,
                "Threads#{d}",
                .{core},
            ) },
        });
        try s.write(ProcessSortIndexEvent{
            .pid = core,
            .args = .{ .sort_index = @intCast(core * 2) },
        });

        // Record scheduling process name.
        try s.write(CoreNameEvent{
            .pid = cpu_pid_base + core,
            .args = .{ .name = try std.fmt.bufPrint(
                &name_buf,
                "Switch#{d}",
                .{core},
            ) },
        });
        try s.write(ProcessSortIndexEvent{
            .pid = cpu_pid_base + core,
            .args = .{ .sort_index = @intCast(core * 2 + 1) },
        });
        try s.write(ThreadNameEvent{
            .pid = cpu_pid_base + core,
            .tid = 0,
            .args = .{ .name = "Running" },
        });
    }

    // Collect the known name for each core and thread pair.
    {
        thread_names = std.AutoHashMap(
            ThreadKey,
            [perf.ThreadName.max_len]u8,
        ).init(allocator);
        for (records) |rec| {
            if (rec.payload.event() != .thread_name) continue;
            try thread_names.put(
                .{ .core = rec.core, .tid = rec.tid },
                rec.payload.data.thread_name.name,
            );
        }
    }

    // Emits thread name events.
    {
        var iter = thread_names.iterator();
        while (iter.next()) |entry| {
            const name = entry.value_ptr.*;
            const len = std.mem.indexOfScalar(u8, &name, 0) orelse name.len;
            try s.write(ThreadNameEvent{
                .pid = entry.key_ptr.core,
                .tid = entry.key_ptr.tid,
                .args = .{ .name = name[0..len] },
            });
        }
    }

    // Pair up enter and exit records per thread.
    var pending = std.AutoHashMap(u32, perf.Record).init(allocator);
    defer pending.deinit();
    for (records) |rec| {
        switch (rec.payload.event()) {
            .thread_name,
            .sched_switch,
            => {
                // Handled later.
            },
            .syscall_enter => {
                try pending.put(rec.tid, rec);
            },
            .syscall_exit => {
                const enter = pending.fetchRemove(rec.tid) orelse {
                    continue;
                };
                try writeSvcEvent(
                    &s,
                    enter.value,
                    rec.timestamp_ns - enter.value.timestamp_ns,
                );
            },
        }
    }

    // Unterminated syscalls stay open.
    var it = pending.iterator();
    while (it.next()) |entry| {
        const enter = entry.value_ptr.*;
        try writeSvcEvent(&s, enter, max_ts - enter.timestamp_ns);
    }

    // Pair up sched_switch records per core into running slices.
    {
        const last_switch = try allocator.alloc(?perf.Record, max_core + 1);
        defer allocator.free(last_switch);
        @memset(last_switch, null);

        for (records) |rec| {
            if (rec.payload.event() != .sched_switch) continue;
            if (last_switch[rec.core]) |prev| {
                try writeSchedEvent(&s, prev, rec.timestamp_ns - prev.timestamp_ns);
            }
            last_switch[rec.core] = rec;
        }
        for (last_switch) |maybe_prev| {
            const prev = maybe_prev orelse continue;
            try writeSchedEvent(&s, prev, max_ts - prev.timestamp_ns);
        }
    }

    // Flush the JSON output.
    try s.endArray();
    try w.flush();
}

const TraceEvent = struct {
    /// Name of the event.
    name: []const u8,
    /// Category
    cat: []const u8,
    /// Phase. Complete event.
    ph: []const u8 = "X",
    /// Process ID
    pid: u32,
    /// Thread ID
    tid: u32,
    /// Timestamp in microseconds
    ts: u64,
    /// Duration
    dur: u64,
};

const CoreNameEvent = struct {
    name: []const u8 = "process_name",
    /// Category. Metadata.
    ph: []const u8 = "M",
    /// Logical core ID.
    pid: u32,
    /// Name of the process.
    args: struct { name: []const u8 },
};

const ProcessSortIndexEvent = struct {
    name: []const u8 = "process_sort_index",
    /// Category. Metadata.
    ph: []const u8 = "M",
    /// Logical core ID.
    pid: u32,
    /// Desired display order among processes.
    args: struct { sort_index: i32 },
};

const ThreadNameEvent = struct {
    name: []const u8 = "thread_name",
    /// Category. Metadata.
    ph: []const u8 = "M",
    /// Logical core ID.
    pid: u32,
    /// Thread ID.
    tid: u32,
    /// Name of the thread.
    args: struct { name: []const u8 },
};

/// Key identifying a thread within a specific core's track.
const ThreadKey = struct {
    /// Logical core ID.
    core: u32,
    /// Thread ID.
    tid: u32,
};

/// Known name for each core and thread pair.
var thread_names: std.AutoHashMap(ThreadKey, [perf.ThreadName.max_len]u8) = undefined;
/// Process ID base for the per-core scheduling process.
var cpu_pid_base: u32 = undefined;

/// Write a sched_switch record and its duration as a complete event.
fn writeSchedEvent(s: *std.json.Stringify, event: perf.Record, duration_ns: u64) !void {
    var name_buf: [32]u8 = undefined;
    const name = blk: {
        const raw = thread_names.get(.{
            .core = event.core,
            .tid = event.tid,
        }) orelse break :blk try std.fmt.bufPrint(
            &name_buf,
            "#{d}",
            .{event.tid},
        );
        const len = std.mem.indexOfScalar(u8, &raw, 0) orelse raw.len;
        @memcpy(name_buf[0..len], raw[0..len]);
        break :blk name_buf[0..len];
    };

    try s.write(TraceEvent{
        .name = name,
        .cat = "sched",
        .pid = cpu_pid_base + event.core,
        .tid = 0,
        .ts = event.timestamp_ns / std.time.ns_per_us,
        .dur = duration_ns / std.time.ns_per_us,
    });
}

/// Write an enter record and its duration as a complete event.
fn writeSvcEvent(s: *std.json.Stringify, event: perf.Record, duration_ns: u64) !void {
    const nr = event.payload.data.syscall_enter.nr;

    var name_buf: [16]u8 = undefined;
    try s.write(TraceEvent{
        .name = try std.fmt.bufPrint(&name_buf, "SVC#{d}", .{nr}),
        .cat = "syscall",
        .pid = event.core,
        .tid = event.tid,
        .ts = event.timestamp_ns / std.time.ns_per_us,
        .dur = duration_ns / std.time.ns_per_us,
    });
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.uperf);
const common = @import("common");
const perf = common.perf;
