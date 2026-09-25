// =============================================================
// Argument validation

test "with an unopened fd fails with EBADF" {
    const ret = linux.flock(999, LOCK_SH);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "with a negative fd fails with EBADF" {
    const ret = linux.flock(-1, LOCK_EX);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "with a closed fd fails with EBADF" {
    try createFile();
    defer deleteFile();

    const fd = try openFile(.{ .ACCMODE = .RDWR });
    try testing.expectEqual(.SUCCESS, linux.errno(linux.close(fd)));

    const ret = linux.flock(fd, LOCK_EX);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "invalid combination of operations fails with EINVAL" {
    try createFile();
    defer deleteFile();

    const ops = [_]i32{
        0,
        LOCK_NB,
        LOCK_SH | LOCK_EX,
        LOCK_SH | LOCK_UN,
        LOCK_EX | LOCK_UN,
        0x100,
    };

    const fd = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd);

    for (ops) |op| {
        const ret = linux.flock(fd, op);
        try testing.expectEqual(.INVAL, linux.errno(ret));
    }
}

// =============================================================
// Basic operations

test "basic locking on an unlocked file succeeds and returns 0" {
    try createFile();
    defer deleteFile();

    const fd = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd);

    const ops = [_]i32{
        LOCK_SH,
        LOCK_EX,
        LOCK_SH | LOCK_NB,
        LOCK_EX | LOCK_NB,
    };

    for (ops) |op| {
        const ret = linux.flock(fd, op);
        defer _ = linux.flock(fd, LOCK_UN);
        try testing.expectEqual(.SUCCESS, linux.errno(ret));
        try testing.expectEqual(0, ret);
    }
}

test "LOCK_UN releases a held lock and returns 0" {
    try createFile();
    defer deleteFile();

    const fd = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd);

    try expectFlockSuccess(fd, LOCK_EX);
    const ret = linux.flock(fd, LOCK_UN);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(0, ret);
}

test "LOCK_UN without holding a lock succeeds" {
    try createFile();
    defer deleteFile();

    const fd = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd);

    const op = [_]i32{
        LOCK_UN,
        LOCK_UN | LOCK_NB,
    };
    for (op) |o| {
        try expectFlockSuccess(fd, o);
    }
}

test "LOCK_UN twice succeeds" {
    try createFile();
    defer deleteFile();

    const fd = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd);

    try expectFlockSuccess(fd, LOCK_SH);
    try expectFlockSuccess(fd, LOCK_UN);
    try expectFlockSuccess(fd, LOCK_UN);
}

test "LOCK_SH or LOCK_EX twice on the same fd succeeds" {
    try createFile();
    defer deleteFile();

    const fd = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd);

    try expectFlockSuccess(fd, LOCK_SH);
    try expectFlockSuccess(fd, LOCK_SH | LOCK_NB);
}

test "LOCK_EX twice on the same fd succeeds" {
    try createFile();
    defer deleteFile();

    const fd = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd);

    try expectFlockSuccess(fd, LOCK_EX);
    try expectFlockSuccess(fd, LOCK_EX | LOCK_NB);
}

test "LOCK_EX can be placed on a read-only fd" {
    try createFile();
    defer deleteFile();

    const fd = try openFile(.{ .ACCMODE = .RDONLY });
    defer closeFd(fd);

    try expectFlockSuccess(fd, LOCK_EX | LOCK_NB);
}

test "LOCK_SH can be placed on a write-only fd" {
    try createFile();
    defer deleteFile();

    const fd = try openFile(.{ .ACCMODE = .WRONLY });
    defer closeFd(fd);

    try expectFlockSuccess(fd, LOCK_SH | LOCK_NB);
}

test "can lock a directory" {
    const fd1 = linux.openat(linux.AT.FDCWD, "/", .{ .DIRECTORY = true }, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd1));
    defer closeFd(@intCast(fd1));
    const fd2 = linux.openat(linux.AT.FDCWD, "/", .{ .DIRECTORY = true }, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd2));
    defer closeFd(@intCast(fd2));

    try expectFlockSuccess(@intCast(fd1), LOCK_EX | LOCK_NB);
    try expectFlockBlock(@intCast(fd2), LOCK_SH | LOCK_NB);
    try expectFlockSuccess(@intCast(fd1), LOCK_UN);
    try expectFlockSuccess(@intCast(fd2), LOCK_SH | LOCK_NB);
}

// =============================================================
// Conflicts between open file descriptions

test "conflicts with another lock of the same file" {
    try createFile();
    defer deleteFile();

    const fd1 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd1);
    const fd2 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd2);

    const pairs = [_][2]i32{
        .{ LOCK_EX, LOCK_EX | LOCK_NB },
        .{ LOCK_EX, LOCK_SH | LOCK_NB },
        .{ LOCK_SH, LOCK_EX | LOCK_NB },
    };

    for (pairs) |pair| {
        try expectFlockSuccess(fd1, pair[0]);
        try expectFlockBlock(fd2, pair[1]);
    }
}

test "multiple LOCK_SH can be held via different opens of the same file" {
    try createFile();
    defer deleteFile();

    const fd1 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd1);
    const fd2 = try openFile(.{ .ACCMODE = .RDONLY });
    defer closeFd(fd2);
    const fd3 = try openFile(.{ .ACCMODE = .WRONLY });
    defer closeFd(fd3);

    try expectFlockSuccess(fd1, LOCK_SH);
    try expectFlockSuccess(fd2, LOCK_SH | LOCK_NB);
    try expectFlockSuccess(fd3, LOCK_SH | LOCK_NB);
}

test "lock can be acquired after the conflicting lock is released by LOCK_UN" {
    try createFile();
    defer deleteFile();

    const fd1 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd1);
    const fd2 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd2);

    try expectFlockSuccess(fd1, LOCK_EX);
    try expectFlockBlock(fd2, LOCK_EX | LOCK_NB);
    try expectFlockSuccess(fd1, LOCK_UN);
    try expectFlockSuccess(fd2, LOCK_EX | LOCK_NB);
}

test "LOCK_UN via another open of the same file does not release the lock" {
    try createFile();
    defer deleteFile();

    const fd1 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd1);
    const fd2 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd2);
    const fd3 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd3);

    try expectFlockSuccess(fd1, LOCK_EX);
    try expectFlockSuccess(fd2, LOCK_UN);
    try expectFlockBlock(fd3, LOCK_SH | LOCK_NB);
}

test "closing the fd releases the lock" {
    try createFile();
    defer deleteFile();

    var fd1 = try openFile(.{ .ACCMODE = .RDWR });
    const fd2 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd2);

    {
        try expectFlockSuccess(fd1, LOCK_EX);
        try expectFlockBlock(fd2, LOCK_EX | LOCK_NB);
        try testing.expectEqual(.SUCCESS, linux.errno(linux.close(fd1)));
        try expectFlockSuccess(fd2, LOCK_EX | LOCK_NB);
        try expectFlockSuccess(fd2, LOCK_UN);
    }
    fd1 = try openFile(.{ .ACCMODE = .RDWR });
    {
        try expectFlockSuccess(fd1, LOCK_SH);
        try testing.expectEqual(.SUCCESS, linux.errno(linux.close(fd1)));
        try expectFlockSuccess(fd2, LOCK_EX | LOCK_NB);
    }
}

test "closing an unrelated fd of the same file does not release the lock" {
    try createFile();
    defer deleteFile();

    const fd1 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd1);
    const fd2 = try openFile(.{ .ACCMODE = .RDWR });
    const fd3 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd3);

    try expectFlockSuccess(fd1, LOCK_EX);
    try testing.expectEqual(.SUCCESS, linux.errno(linux.close(fd2)));
    try expectFlockBlock(fd3, LOCK_EX | LOCK_NB);
}

// =============================================================
// Lock conversion

test "LOCK_EX can be downgraded to LOCK_SH" {
    try createFile();
    defer deleteFile();

    const fd1 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd1);
    const fd2 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd2);

    try expectFlockSuccess(fd1, LOCK_EX);
    try expectFlockSuccess(fd1, LOCK_SH);
    try expectFlockSuccess(fd2, LOCK_SH | LOCK_NB);
}

test "upgrading succeeds after the other LOCK_SH holder releases" {
    try createFile();
    defer deleteFile();

    const fd1 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd1);
    const fd2 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd2);

    try expectFlockSuccess(fd1, LOCK_SH);
    try expectFlockSuccess(fd2, LOCK_SH);
    try expectFlockSuccess(fd2, LOCK_UN);

    try expectFlockSuccess(fd1, LOCK_EX | LOCK_NB);
}

// =============================================================
// Duplicated file descriptors

test "fd created by dup shares the lock" {
    try createFile();
    defer deleteFile();

    const fd1 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd1);
    const dupfd = linux.dup(fd1);
    try testing.expectEqual(.SUCCESS, linux.errno(dupfd));
    defer closeFd(@intCast(dupfd));
    const fd2 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd2);

    try expectFlockSuccess(fd1, LOCK_EX);
    try expectFlockSuccess(@intCast(dupfd), LOCK_EX | LOCK_NB);
    try expectFlockBlock(fd2, LOCK_SH | LOCK_NB);
}

test "LOCK_UN via a dup'ed fd releases the lock placed via the original fd" {
    try createFile();
    defer deleteFile();

    const fd1 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd1);
    const dupfd = linux.dup(fd1);
    try testing.expectEqual(.SUCCESS, linux.errno(dupfd));
    defer closeFd(@intCast(dupfd));
    const fd2 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd2);

    try expectFlockSuccess(fd1, LOCK_EX);
    try expectFlockBlock(fd2, LOCK_EX | LOCK_NB);
    try expectFlockSuccess(@intCast(dupfd), LOCK_UN);
    try expectFlockSuccess(fd2, LOCK_EX | LOCK_NB);
}

// =============================================================
// Processes

var shared_fd: i32 = undefined;

test "LOCK_EX held by the parent conflicts with the child's" {
    try createFile();
    defer deleteFile();

    shared_fd = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(shared_fd);
    try expectFlockSuccess(shared_fd, LOCK_EX);

    try utest.runChild(struct {
        pub fn lambda() !void {
            const fd = try openFile(.{ .ACCMODE = .RDWR });
            defer closeFd(fd);

            try expectFlockBlock(fd, LOCK_EX | LOCK_NB);
            try expectFlockBlock(fd, LOCK_SH | LOCK_NB);
        }
    });
}

test "LOCK_SH held by the parent can be locked again with the child's LOCK_SH" {
    try createFile();
    defer deleteFile();

    shared_fd = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(shared_fd);
    try expectFlockSuccess(shared_fd, LOCK_SH);

    try utest.runChild(struct {
        pub fn lambda() !void {
            const fd = try openFile(.{ .ACCMODE = .RDWR });
            defer closeFd(fd);

            try expectFlockSuccess(fd, LOCK_SH | LOCK_NB);
            try expectFlockBlock(fd, LOCK_EX | LOCK_NB);
        }
    });
}

test "a child with the same fd shares the parent's lock" {
    try createFile();
    defer deleteFile();

    shared_fd = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(shared_fd);
    try expectFlockSuccess(shared_fd, LOCK_EX);

    try utest.runChild(struct {
        pub fn lambda() !void {
            try expectFlockSuccess(shared_fd, LOCK_EX | LOCK_NB);
            try expectFlockSuccess(shared_fd, LOCK_EX | LOCK_NB);
            try expectFlockSuccess(shared_fd, LOCK_SH | LOCK_NB);
        }
    });
}

test "LOCK_UN by a child via the same fd releases the parent's lock" {
    try createFile();
    defer deleteFile();

    shared_fd = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(shared_fd);
    try expectFlockSuccess(shared_fd, LOCK_EX);

    try utest.runChild(struct {
        pub fn lambda() !void {
            try expectFlockSuccess(shared_fd, LOCK_UN);
        }
    });

    const fd2 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd2);
    try expectFlockSuccess(fd2, LOCK_EX | LOCK_NB);
}

test "a lock placed by a child via the same fd persists after the child exits" {
    try createFile();
    defer deleteFile();

    shared_fd = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(shared_fd);

    try utest.runChild(struct {
        pub fn lambda() !void {
            try expectFlockSuccess(shared_fd, LOCK_EX);
        }
    });

    const fd2 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd2);
    try expectFlockBlock(fd2, LOCK_SH | LOCK_NB);

    try expectFlockSuccess(shared_fd, LOCK_UN);
    try expectFlockSuccess(fd2, LOCK_EX | LOCK_NB);
}

test "the child's exit does not release the lock held via the inherited fd" {
    try createFile();
    defer deleteFile();

    shared_fd = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(shared_fd);
    try expectFlockSuccess(shared_fd, LOCK_EX);

    try utest.runChild(struct {
        pub fn lambda() !void {
            closeFd(shared_fd);
        }
    });

    const fd2 = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd2);
    try expectFlockBlock(fd2, LOCK_SH | LOCK_NB);
}

test "a lock held via the child's own open is released when the child exits" {
    try createFile();
    defer deleteFile();

    try utest.runChild(struct {
        pub fn lambda() !void {
            const fd = try openFile(.{ .ACCMODE = .RDWR });
            try expectFlockSuccess(fd, LOCK_EX);
        }
    });

    const fd = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd);
    try expectFlockSuccess(fd, LOCK_EX | LOCK_NB);
}

// =============================================================
// Blocking

test "blocking LOCK_EX waits until a conflicting LOCK_EX is released" {
    try expectBlockedUntilRelease(LOCK_EX, LOCK_EX);
}

test "blocking LOCK_EX waits until a conflicting LOCK_SH is released" {
    try expectBlockedUntilRelease(LOCK_SH, LOCK_EX);
}

test "blocking LOCK_SH waits until a conflicting LOCK_EX is released" {
    try expectBlockedUntilRelease(LOCK_EX, LOCK_SH);
}

// =============================================================
// Helpers
// =============================================================

const LOCK_SH = 1;
const LOCK_EX = 2;
const LOCK_NB = 4;
const LOCK_UN = 8;

/// Path of the file used for locking.
const path = "/flock.txt";

fn createFile() !void {
    const fd = linux.openat(linux.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    closeFd(@intCast(fd));
}

fn deleteFile() void {
    _ = linux.unlinkat(linux.AT.FDCWD, path, 0);
}

fn openFile(flags: linux.O) !i32 {
    const fd = linux.openat(linux.AT.FDCWD, path, flags, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    return @intCast(fd);
}

fn closeFd(fd: i32) void {
    if (fd >= 0) _ = linux.close(fd);
}

fn expectFlockSuccess(fd: i32, op: i32) !void {
    const ret = linux.flock(fd, op);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(0, ret);
}

fn expectFlockBlock(fd: i32, op: i32) !void {
    try testing.expectEqual(.AGAIN, linux.errno(linux.flock(fd, op)));
}

fn expectBlockedUntilRelease(op_held: i32, op_request: i32) !void {
    try createFile();
    defer deleteFile();

    const fd = try openFile(.{ .ACCMODE = .RDWR });
    defer closeFd(fd);
    try expectFlockSuccess(fd, op_held);

    var fds: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{
        .NONBLOCK = true,
    })));
    defer closeFd(fds[0]);

    const pid = forkLocker(op_request, fds[1], fd);
    try testing.expect(pid > 0);
    closeFd(fds[1]);

    // The child must still be blocked.
    sleepMs(50);
    var buf: [1]u8 = undefined;
    const early = linux.errno(linux.read(fds[0], &buf, 1));
    try testing.expectEqual(.AGAIN, early);

    try expectFlockSuccess(fd, LOCK_UN);
    try expectWaitChildTimeout(pid, 0);
    try testing.expectEqual(1, linux.read(fds[0], &buf, 1));
}

fn sleepMs(ms: u64) void {
    _ = linux.nanosleep(&.{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    }, null);
}

/// Fork a child that opens the file and takes a specified lock.
///
/// The child closes the `close_fd` first if given.
/// After the lock is acquired, the child writes a byte to `notify_fd` if given.
fn forkLocker(op: i32, notify_fd: ?i32, close_fd: ?i32) linux.pid_t {
    const ret = linux.fork();
    if (ret == 0) {
        if (close_fd) |cfd| {
            closeFd(cfd); // decrement the refcnt of the fd
        }
        const fd = openFile(.{
            .ACCMODE = .RDWR,
        }) catch linux.exit_group(1);

        if (linux.errno(linux.flock(fd, op)) != .SUCCESS) {
            linux.exit_group(2);
        }
        if (notify_fd) |nfd| {
            if (linux.write(nfd, "x", 1) != 1) {
                linux.exit_group(3);
            }
        }
        linux.exit_group(0);
    }
    return @intCast(ret);
}

/// Wait for the child to exit with the expected exit code.
fn expectWaitChildTimeout(pid: linux.pid_t, expected_code: u32) !void {
    const timeout_ms = 3000;
    const interval_ms = 10;

    // Wait for the child to exit until the timeout is reached.
    var status: u32 = undefined;
    var elapsed: u64 = 0;
    while (elapsed < timeout_ms) : (elapsed += interval_ms) {
        const ret = linux.wait4(pid, &status, linux.W.NOHANG, null);
        try testing.expectEqual(.SUCCESS, linux.errno(ret));
        if (ret == @as(usize, @intCast(pid))) {
            try testing.expect(linux.W.IFEXITED(status));
            try testing.expectEqual(expected_code, linux.W.EXITSTATUS(status));
            return;
        }
        sleepMs(interval_ms);
    }

    // Timeout.
    _ = linux.kill(pid, .KILL);
    for (0..timeout_ms / interval_ms) |_| {
        if (linux.wait4(
            pid,
            &status,
            linux.W.NOHANG,
            null,
        ) == @as(usize, @intCast(pid))) break;
        sleepMs(interval_ms);
    }
    return error.Timeout;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
