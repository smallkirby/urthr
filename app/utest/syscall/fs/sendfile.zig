test "sendfile copies the whole file and advances both offsets" {
    const content = "0123456789";
    try createSrc(content);
    defer deleteFile(src_name);

    const in_fd = openSrcReadOnly();
    defer _ = linux.close(in_fd);

    const out_fd = createDst();
    defer _ = linux.close(out_fd);
    defer deleteFile(dst_name);

    const ret = linux.sendfile(out_fd, in_fd, null, content.len);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@as(usize, content.len), ret);

    // File offset must be advanced.
    const in_pos = linux.lseek(in_fd, 0, linux.SEEK.CUR);
    try testing.expectEqual(@as(usize, content.len), in_pos);

    // Destination content is expected.
    var buf: [content.len]u8 = undefined;
    const wfd = openDstReadOnly();
    defer _ = linux.close(wfd);
    const n = linux.read(wfd, &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(n));
    try testing.expectEqualSlices(u8, content, buf[0..n]);
}

test "sendfile does not move file offset when offset pointer is given" {
    const content = "0123456789";
    try createSrc(content);
    defer deleteFile(src_name);

    const in_fd = openSrcReadOnly();
    defer _ = linux.close(in_fd);

    const out_fd = createDst();
    defer _ = linux.close(out_fd);
    defer deleteFile(dst_name);

    var off: i64 = 4;
    const ret = linux.sendfile(out_fd, in_fd, &off, 4);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@as(usize, 4), ret);
    try testing.expectEqual(@as(i64, 8), off);

    // Source file offset does not move.
    const in_pos = linux.lseek(in_fd, 0, linux.SEEK.CUR);
    try testing.expectEqual(@as(usize, 0), in_pos);

    // Destination content is expected.
    var buf: [4]u8 = undefined;
    const wfd = openDstReadOnly();
    defer _ = linux.close(wfd);
    const n = linux.read(wfd, &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(n));
    try testing.expectEqualSlices(u8, "4567", buf[0..n]);
}

test "with an unopened in_fd fails with EBADF" {
    const out_fd = createDst();
    defer _ = linux.close(out_fd);
    defer deleteFile(dst_name);

    const ret = linux.sendfile(out_fd, 999, null, 4);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "with a out_fd opened in read-only mode fails with EBADF" {
    const content = "0123456789";
    try createSrc(content);
    defer deleteFile(src_name);

    const in_fd = openSrcReadOnly();
    defer _ = linux.close(in_fd);

    const out_fd = openSrcReadOnly();
    defer _ = linux.close(out_fd);

    const ret = linux.sendfile(out_fd, in_fd, null, 4);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

// =============================================================
// Helpers
// =============================================================

const src_name = "sfsrc.txt";
const dst_name = "sfdst.txt";

/// Create a file with the given content in the base directory.
fn createSrc(content: []const u8) !void {
    const init = utest.getInit();
    const dir = try std.Io.Dir.openDirAbsolute(init.io, Test.base_dir, .{});
    defer dir.close(init.io);

    const file = try dir.createFile(init.io, src_name, .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, content);
}

/// Delete the file with the given name in the base directory.
fn deleteFile(name: []const u8) void {
    const init = utest.getInit();
    const dir = std.Io.Dir.openDirAbsolute(init.io, Test.base_dir, .{}) catch |err| {
        std.log.err("Failed to open base directory: {t}", .{err});
        std.process.exit(1);
    };
    defer dir.close(init.io);

    dir.deleteFile(init.io, name) catch |err| {
        std.log.err("Failed to delete file: {t}", .{err});
        std.process.exit(1);
    };
}

/// Open the source file in read-only mode.
fn openSrcReadOnly() linux.fd_t {
    const fd = linux.openat(
        linux.AT.FDCWD,
        Test.base_dir ++ src_name,
        .{ .ACCMODE = .RDONLY },
        0,
    );
    testing.expectEqual(.SUCCESS, linux.errno(fd)) catch unreachable;
    return @intCast(fd);
}

/// Create the destination file in write-only mode.
fn createDst() linux.fd_t {
    const fd = linux.openat(
        linux.AT.FDCWD,
        Test.base_dir ++ dst_name,
        .{ .ACCMODE = .WRONLY, .CREAT = true },
        0o644,
    );
    testing.expectEqual(.SUCCESS, linux.errno(fd)) catch unreachable;
    return @intCast(fd);
}

/// Open the destination file in read-only mode.
fn openDstReadOnly() linux.fd_t {
    const fd = linux.openat(
        linux.AT.FDCWD,
        Test.base_dir ++ dst_name,
        .{ .ACCMODE = .RDONLY },
        0,
    );
    testing.expectEqual(.SUCCESS, linux.errno(fd)) catch unreachable;
    return @intCast(fd);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const Test = utest.fs.Test;
