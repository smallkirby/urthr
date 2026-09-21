const S = struct {
    var shared_pid = std.atomic.Value(i32).init(0);

    fn threadMain(_: usize) callconv(.c) u8 {
        shared_pid.store(@intCast(linux.getpid()), .release);
        linux.exit(0);
    }
};

test "syscall: clone with CLONE_THREAD shares the address space and tgid" {
    S.shared_pid.store(0, .release);

    const parent_pid = linux.getpid();
    const parent_tid = linux.gettid();

    const child_tid = try utest.task.spawnThread(S.threadMain, 0);
    try testing.expect(child_tid != parent_tid);

    // Wait for the new thread to run and publish its write.
    var spins: usize = 0;
    while (S.shared_pid.load(.acquire) == 0) : (spins += 1) {
        if (spins > 100_000) return error.TestUnexpectedResult;
        _ = linux.sched_yield();
    }

    // PID is shared between parent and child.
    try testing.expectEqual(@as(i32, @intCast(parent_pid)), S.shared_pid.load(.acquire));
}

// =============================================================
// CLONE_FS

test "clone with CLONE_FS shares CWD with the parent" {
    var oldbuf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try getcwd(&oldbuf);
    defer chdir(orig) catch unreachable;

    // Change CWD in the child.
    const target = "/bin";
    const ret = linux.syscall5(.clone, linux.CLONE.FS, 0, 0, 0, 0);
    if (ret == 0) {
        const rc = linux.chdir(target);
        linux.exit_group(if (linux.errno(rc) == .SUCCESS) 0 else 1);
    }
    try utest.expectWaitChild(@intCast(ret), 0);

    // Change is visible to the parent.
    var newbuf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualSlices(u8, target, try getcwd(&newbuf));
}

test "clone without CLONE_FS does not share CWD with the parent" {
    var oldbuf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try getcwd(&oldbuf);
    defer chdir(orig) catch unreachable;

    // Change CWD in the child.
    const target = "/bin";
    const ret = linux.syscall5(.clone, 0, 0, 0, 0, 0);
    if (ret == 0) {
        const rc = linux.chdir(target);
        linux.exit_group(if (linux.errno(rc) == .SUCCESS) 0 else 1);
    }
    try utest.expectWaitChild(@intCast(ret), 0);

    // Change is not visible to the parent.
    var newbuf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualSlices(u8, orig, try getcwd(&newbuf));
}

test "clone with CLONE_FS shares umask with the parent" {
    const orig = getUmask();
    defer _ = umask(orig);

    // Change umask in the child.
    const ret = linux.syscall5(.clone, linux.CLONE.FS, 0, 0, 0, 0);
    if (ret == 0) {
        _ = umask(0o071);
        linux.exit_group(0);
    }
    try utest.expectWaitChild(@intCast(ret), 0);

    // Change is visible to the parent.
    try testing.expectEqual(@as(usize, 0o071), getUmask());
}

test "clone without CLONE_FS does not share umask with the parent" {
    const orig = getUmask();
    defer _ = umask(orig);

    // Change umask in the child.
    const ret = linux.syscall5(.clone, 0, 0, 0, 0, 0);
    if (ret == 0) {
        _ = umask(0o071);
        linux.exit_group(0);
    }
    try utest.expectWaitChild(@intCast(ret), 0);

    // Change is not visible to the parent.
    try testing.expectEqual(orig, getUmask());
}

// =============================================================
// Helpers
// =============================================================

fn getcwd(buf: []u8) ![:0]const u8 {
    const rc = linux.getcwd(buf.ptr, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(rc));
    return buf[0..std.mem.span(@as([*:0]u8, @ptrCast(buf.ptr))).len :0];
}

fn chdir(path: [:0]const u8) !void {
    const rc = linux.chdir(path.ptr);
    try testing.expectEqual(.SUCCESS, linux.errno(rc));
}

fn umask(mask: usize) usize {
    return linux.syscall1(.umask, mask);
}

fn getUmask() usize {
    const cur = umask(0o022);
    _ = umask(cur);
    return cur;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
