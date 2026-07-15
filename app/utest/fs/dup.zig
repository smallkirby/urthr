test "dup3 succeeds and both fds refer to the same file" {
    const init = utest.getInit();
    var t = Test.init();

    const content = "0123456789";
    const wfile = try t.createFile();
    try wfile.writeStreamingAll(init.io, content);
    wfile.close(init.io);
    defer t.deleteFile();

    const fd = linux.openat(
        linux.AT.FDCWD,
        Test.base_dir ++ "/" ++ Test.file_name,
        .{},
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const newfd = 42;
    const ret = linux.dup3(@intCast(fd), newfd, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(newfd, ret);
    defer _ = linux.close(newfd);

    // Both fds share the same file offset.
    var buf: [4]u8 = undefined;
    const nread = linux.read(newfd, &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(nread));
    try testing.expectEqualSlices(u8, content[0..4], &buf);

    const pos = linux.lseek(@intCast(fd), 0, linux.SEEK.CUR);
    try testing.expectEqual(@as(usize, 4), pos);
}

test "dup3 with equal oldfd and newfd fails with EINVAL" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const ret = linux.dup3(@intCast(fd), @intCast(fd), 0);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "dup3 with an unopened oldfd fails with EBADF" {
    const ret = linux.dup3(999, 50, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "dup3 with a negative newfd fails with EBADF" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const ret = linux.dup3(@intCast(fd), -1, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "dup3 closes an already-open newfd before reuse" {
    const init = utest.getInit();
    var t = Test.init();

    const content = "0123456789";
    const wfile = try t.createFile();
    try wfile.writeStreamingAll(init.io, content);
    wfile.close(init.io);
    defer t.deleteFile();

    // Occupy newfd with the content file first to guarantee its fd number.
    const newfd = 43;
    {
        const content_fd = linux.openat(
            linux.AT.FDCWD,
            Test.base_dir ++ "/" ++ Test.file_name,
            .{},
            0,
        );
        try testing.expectEqual(.SUCCESS, linux.errno(content_fd));
        defer _ = linux.close(@intCast(content_fd));

        const ret = linux.dup3(@intCast(content_fd), newfd, 0);
        try testing.expectEqual(.SUCCESS, linux.errno(ret));
    }

    // dup3 onto an already-open newfd must succeed and transparently replace it.
    const elf_fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(elf_fd));
    defer _ = linux.close(@intCast(elf_fd));

    const ret = linux.dup3(@intCast(elf_fd), newfd, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.close(newfd);

    // newfd must now refer to the ELF file, not the stale content file.
    var buf: [4]u8 = undefined;
    const nread = linux.read(newfd, &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(nread));
    try testing.expectEqualSlices(u8, std.elf.MAGIC, &buf);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const Test = utest.fs.Test;
