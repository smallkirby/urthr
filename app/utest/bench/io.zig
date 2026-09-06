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

test "large directory lookup" {
    const init = utest.getInit();

    const counts = [_]usize{ 8, 32, 64, 128, 256, 512, 1024, 2048 };
    const probes = 64;
    const getdents_max = 1024;

    // Create benchmark root directory.
    const root = "/bench";
    _ = linux.unlinkat(linux.AT.FDCWD, root, linux.AT.REMOVEDIR);
    try testing.expectEqual(.SUCCESS, linux.errno(linux.mkdirat(
        linux.AT.FDCWD,
        root,
        0o755,
    )));
    defer _ = linux.unlinkat(linux.AT.FDCWD, root, linux.AT.REMOVEDIR);

    var dir = try std.Io.Dir.openDirAbsolute(init.io, root, .{});
    defer dir.close(init.io);
    const dirfd: i32 = @intCast(dir.handle);

    var created: usize = 0;
    defer for (0..created) |i| {
        var nbuf: [16]u8 = undefined;
        _ = linux.unlinkat(dirfd, lookupName(&nbuf, i), 0);
    };

    var statbuf: [512]u8 = undefined;
    var prev_pos: u64 = 0;
    var prev_neg: u64 = 0;

    for (counts) |count| {
        // Create a `count` number of files.
        while (created < count) : (created += 1) {
            var nbuf: [16]u8 = undefined;
            const fd = linux.openat(dirfd, lookupName(&nbuf, created), .{
                .ACCMODE = .WRONLY,
                .CREAT = true,
                .EXCL = true,
            }, 0o644);
            if (linux.errno(fd) != .SUCCESS) {
                std.log.warn("stopped at {d} files ({t})", .{ created, linux.errno(fd) });
                return;
            }
            _ = linux.close(@intCast(fd));
        }

        // Mostly hits the dentry cache rather than performing a full directory scan.
        const pos_start = now();
        for (0..probes) |k| {
            var nbuf: [16]u8 = undefined;
            const ret = statAt(
                dirfd,
                lookupName(&nbuf, k * count / probes),
                &statbuf,
            );
            try testing.expectEqual(.SUCCESS, linux.errno(ret));
        }
        const pos_end = now();

        // A never-matching name is not cached and forces a full directory scan.
        const neg_start = now();
        for (0..probes) |_| {
            try testing.expectEqual(.NOENT, linux.errno(
                statAt(dirfd, "nomatch", &statbuf),
            ));
        }
        const neg_end = now();

        const pos_ns = (pos_end - pos_start) / probes;
        const neg_ns = (neg_end - neg_start) / probes;
        const pos_ratio = if (prev_pos != 0) pos_ns * 100 / prev_pos else 0;
        const neg_ratio = if (prev_neg != 0) neg_ns * 100 / prev_neg else 0;
        prev_pos = pos_ns;
        prev_neg = neg_ns;

        std.log.info(
            "{d: >4} files: pos-stat {d: >4} ns/op (x{d}.{d:0>2}), neg-stat {d: >8} ns/op (x{d}.{d:0>2})",
            .{ count, pos_ns, pos_ratio / 100, pos_ratio % 100, neg_ns, neg_ratio / 100, neg_ratio % 100 },
        );

        if (count > getdents_max) continue;

        // getdents64 benchmark.
        var iter = try std.Io.Dir.openDirAbsolute(init.io, root, .{ .iterate = true });
        defer iter.close(init.io);
        var entries: usize = 0;
        var dbuf: [4096]u8 = undefined;
        const gd_start = now();
        while (true) {
            const n = linux.getdents64(@intCast(iter.handle), &dbuf, dbuf.len);
            try testing.expectEqual(.SUCCESS, linux.errno(n));
            if (n == 0) break;
            var off: usize = 0;
            while (off < n) {
                off += std.mem.readInt(u16, dbuf[off + 16 ..][0..2], .little);
                entries += 1;
            }
        }
        std.log.info(
            "{d: >4} files: getdents {d: >10} ns ({d} entries)",
            .{ count, now() - gd_start, entries },
        );
    }
}

// =============================================================
// Helpers
// =============================================================

/// Format the benchmark file name for index `i` into `buf`.
fn lookupName(buf: *[16]u8, i: usize) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "f{d}", .{i}) catch unreachable;
}

///
fn statAt(dirfd: i32, name: [*:0]const u8, buf: []u8) usize {
    return linux.syscall4(
        .fstatat64,
        @intCast(dirfd),
        @intFromPtr(name),
        @intFromPtr(buf.ptr),
        0,
    );
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
const time = utest.time;
