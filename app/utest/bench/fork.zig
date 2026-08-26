//! fork benchmark.

test "fork/wait latency" {
    const iterations = 10;
    // Extra anonymous pages touched before forking.
    const extra_pages = [_]usize{ 0, 32, 128, 512 };

    for (extra_pages) |npages| {
        const region = if (npages > 0)
            try mapAndTouch(npages)
        else
            null;
        defer if (region) |r| {
            _ = linux.munmap(@ptrCast(r.ptr), r.len);
        };

        const start = now();
        for (0..iterations) |_| {
            const pid = linux.fork();
            try testing.expect(linux.errno(pid) == .SUCCESS);

            if (pid == 0) {
                linux.exit_group(0);
                unreachable;
            }

            var status: u32 = undefined;
            const wret = linux.wait4(
                @as(linux.pid_t, @intCast(pid)),
                &status,
                0,
                null,
            );
            try testing.expectEqual(pid, wret);
        }
        const end = now();

        const total_ns = end - start;
        std.log.info(
            "fork bench: {d} extra pages: {d} ns total, {d} ns/op",
            .{ npages, total_ns, total_ns / iterations },
        );
    }
}

// =============================================================
// Helpers
// =============================================================

/// Maps the given number of anonymous pages and touches every page
/// so that they got backed by physical memory and are resident in RAM.
fn mapAndTouch(npages: usize) ![]u8 {
    const page_size = 4096;
    const len = npages * page_size;

    const ret = mem.mmap(
        0,
        len,
        mem.PROT_READ | mem.PROT_WRITE,
        mem.MAP_PRIVATE | mem.MAP_ANONYMOUS,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    const slice = @as([*]u8, @ptrFromInt(ret))[0..len];
    for (0..npages) |i| {
        slice[i * page_size] = 0xAB;
    }
    return slice;
}

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
const mem = utest.mem;
const time = utest.time;
