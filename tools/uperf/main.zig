//! uperf: Convert a raw kernel performance trace dump into a Perfetto-loadable JSON file.
//!
//! cf. https://perfetto.dev/docs/getting-started/other-formats

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

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

    // Start conversion.
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginArray();

    // Record core names.
    // Using process name metadata events for this purpose.
    var core: u32 = 0;
    while (core <= max_core) : (core += 1) {
        var core_name_buf: [16]u8 = undefined;
        try s.write(ProcessNameEvent{
            .pid = core,
            .args = .{ .name = try std.fmt.bufPrint(
                &core_name_buf,
                "Core#{d}",
                .{core},
            ) },
        });
    }

    // Pair up enter and exit records per thread.
    var pending = std.AutoHashMap(u32, perf.Record).init(allocator);
    defer pending.deinit();
    for (records) |rec| {
        switch (rec.payload.event()) {
            .syscall_enter => {
                try pending.put(rec.tid, rec);
            },
            .syscall_exit => {
                const enter = pending.fetchRemove(rec.tid) orelse {
                    continue;
                };
                try writeEvent(
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
        try writeEvent(&s, enter, max_ts - enter.timestamp_ns);
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

const ProcessNameEvent = struct {
    name: []const u8 = "process_name",
    /// Category. Metadata.
    ph: []const u8 = "M",
    /// Process ID.
    pid: u32,
    /// Name of the process.
    args: struct { name: []const u8 },
};

/// Write an enter record and its duration as a complete event.
fn writeEvent(s: *std.json.Stringify, enter: perf.Record, duration_ns: u64) !void {
    const nr = enter.payload.data.syscall_enter.nr;

    var name_buf: [16]u8 = undefined;
    try s.write(TraceEvent{
        .name = try std.fmt.bufPrint(&name_buf, "SVC#{d}", .{nr}),
        .cat = "syscall",
        .pid = enter.core,
        .tid = enter.tid,
        .ts = enter.timestamp_ns / std.time.ns_per_us,
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
