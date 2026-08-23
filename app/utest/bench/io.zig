//! I/O latency benchmark.

test "sequential write/read latency" {
    const path = "/bench.dat";
    const block_size = 4096;
    const iterations = 100;
    var buf: [block_size]u8 = @splat(0xAB);

    const fd = linux.openat(
        linux.AT.FDCWD,
        path,
        .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true },
        0o644,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.unlinkat(linux.AT.FDCWD, path, 0);
    defer _ = linux.close(@intCast(fd));

    const sizes = [_]usize{ 8, 32, 128, 512, 1024, 2048, 4096 };
    for (sizes) |size| {
        _ = linux.ftruncate(@intCast(fd), 0);
        _ = linux.lseek(@intCast(fd), 0, linux.SEEK.SET);

        // write benchmark
        const write_start = now();
        for (0..iterations) |_| {
            const ret = linux.write(@intCast(fd), &buf, size);
            try testing.expectEqual(@as(usize, size), ret);
        }
        const write_end = now();

        _ = linux.lseek(@intCast(fd), 0, linux.SEEK.SET);

        // read benchmark
        const read_start = now();
        for (0..iterations) |_| {
            const ret = linux.read(@intCast(fd), &buf, size);
            try testing.expectEqual(@as(usize, size), ret);
        }
        const read_end = now();

        // Print outputs
        const write_ns = write_end - write_start;
        const read_ns = read_end - read_start;
        std.log.info(
            "I/O bench: {d} bytes: write {d} ns ({d} ns/op), read {d} ns ({d} ns/op)",
            .{
                size,
                write_ns,
                write_ns / iterations,
                read_ns,
                read_ns / iterations,
            },
        );
    }
}

// =============================================================
// Helpers
// =============================================================

/// Get the current monotonic time in nanoseconds.
fn now() u64 {
    var ts: linux.timespec = undefined;
    const ret = time.clockGetTime(time.CLOCK_MONOTONIC, &ts);
    testing.expectEqual(.SUCCESS, linux.errno(ret)) catch unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const time = utest.time;
