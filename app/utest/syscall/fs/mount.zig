test "mount proc onto a fresh directory succeeds and exposes proc files" {
    const init = utest.getInit();
    const dir_path = Test.base_dir ++ "mountt1";
    const file_path = Test.base_dir ++ "mountt1/meminfo";

    const mkdir_ret = linux.mkdir(dir_path, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(mkdir_ret));
    defer _ = linux.rmdir(dir_path);

    const mount_ret = linux.mount("proc", dir_path, "proc", 0, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(mount_ret));

    var file = try std.Io.Dir.openFileAbsolute(init.io, file_path, .{});
    file.close(init.io);
}

test "mount on an already-mounted directory stacks and succeeds" {
    const mount_ret = linux.mount("proc", "/proc", "proc", 0, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(mount_ret));
}

test "mount with an unknown filesystem type fails with ENODEV" {
    const dir_path = Test.base_dir ++ "mountt2";

    const mkdir_ret = linux.mkdir(dir_path, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(mkdir_ret));
    defer _ = linux.rmdir(dir_path);

    const mount_ret = linux.mount("tmpfs", dir_path, "tmpfs", 0, 0);
    try testing.expectEqual(.NODEV, linux.errno(mount_ret));
}

test "mount on a non-existent target fails with ENOENT" {
    const mount_ret = linux.mount("proc", Test.base_dir ++ "mountnoexist", "proc", 0, 0);
    try testing.expectEqual(.NOENT, linux.errno(mount_ret));
}

test "mount with MS_REMOUNT succeeds" {
    const mount_ret = linux.mount(null, "/", null, linux.MS.REMOUNT, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(mount_ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const Test = utest.fs.Test;
