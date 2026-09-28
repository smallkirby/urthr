// =============================================================
// sendfile

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
// copy_file_range

test "copy_file_range copies the whole file and advances both offsets" {
    const content = "0123456789";
    try createSrc(content);
    defer deleteFile(src_name);

    const in_fd = openSrcReadOnly();
    defer _ = linux.close(in_fd);

    const out_fd = createDst();
    defer _ = linux.close(out_fd);
    defer deleteFile(dst_name);

    const ret = linux.copy_file_range(in_fd, null, out_fd, null, content.len, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@as(usize, content.len), ret);

    // Both file offsets must be advanced.
    const in_pos = linux.lseek(in_fd, 0, linux.SEEK.CUR);
    try testing.expectEqual(@as(usize, content.len), in_pos);
    const out_pos = linux.lseek(out_fd, 0, linux.SEEK.CUR);
    try testing.expectEqual(@as(usize, content.len), out_pos);

    // Destination content is expected.
    var buf: [content.len]u8 = undefined;
    const wfd = openDstReadOnly();
    defer _ = linux.close(wfd);
    const n = linux.read(wfd, &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(n));
    try testing.expectEqualSlices(u8, content, buf[0..n]);
}

test "copy_file_range does not move file offsets when offset pointers are given" {
    const content = "0123456789";
    try createSrc(content);
    defer deleteFile(src_name);

    const in_fd = openSrcReadOnly();
    defer _ = linux.close(in_fd);

    const out_fd = createDst();
    defer _ = linux.close(out_fd);
    defer deleteFile(dst_name);

    var off_in: i64 = 4;
    var off_out: i64 = 0;
    const ret = linux.copy_file_range(in_fd, &off_in, out_fd, &off_out, 4, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@as(usize, 4), ret);
    try testing.expectEqual(@as(i64, 8), off_in);
    try testing.expectEqual(@as(i64, 4), off_out);

    // Neither file's own offset moves.
    const in_pos = linux.lseek(in_fd, 0, linux.SEEK.CUR);
    try testing.expectEqual(@as(usize, 0), in_pos);
    const out_pos = linux.lseek(out_fd, 0, linux.SEEK.CUR);
    try testing.expectEqual(@as(usize, 0), out_pos);

    // Destination content is expected.
    var buf: [4]u8 = undefined;
    const wfd = openDstReadOnly();
    defer _ = linux.close(wfd);
    const n = linux.read(wfd, &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(n));
    try testing.expectEqualSlices(u8, "4567", buf[0..n]);
}

test "copy_file_range with an unopened in_fd fails with EBADF" {
    const out_fd = createDst();
    defer _ = linux.close(out_fd);
    defer deleteFile(dst_name);

    const ret = linux.copy_file_range(999, null, out_fd, null, 4, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "copy_file_range with read-only out_fd fails with EBADF" {
    const content = "0123456789";
    try createSrc(content);
    defer deleteFile(src_name);

    const in_fd = openSrcReadOnly();
    defer _ = linux.close(in_fd);

    const out_fd = openSrcReadOnly();
    defer _ = linux.close(out_fd);

    const ret = linux.copy_file_range(in_fd, null, out_fd, null, 4, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "copy_file_range fails with EISDIR when fd_in is a directory" {
    const in_fd = openBaseDir();
    defer _ = linux.close(in_fd);

    const out_fd = createDst();
    defer _ = linux.close(out_fd);
    defer deleteFile(dst_name);

    const ret = linux.copy_file_range(in_fd, null, out_fd, null, 4, 0);
    try testing.expectEqual(.ISDIR, linux.errno(ret));
}

test "copy_file_range fails with EINVAL when source and destination ranges overlap" {
    const content = "0123456789";
    try createSrc(content);
    defer deleteFile(src_name);

    const in_fd = openSrcReadWrite();
    defer _ = linux.close(in_fd);
    const out_fd = openSrcReadWrite();
    defer _ = linux.close(out_fd);

    var off_in: i64 = 0;
    var off_out: i64 = 4;
    const ret = linux.copy_file_range(in_fd, &off_in, out_fd, &off_out, 6, 0);
    try testing.expectEqual(.INVAL, linux.errno(ret));
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

/// Open the source file in read-write mode.
fn openSrcReadWrite() linux.fd_t {
    const fd = linux.openat(
        linux.AT.FDCWD,
        Test.base_dir ++ src_name,
        .{ .ACCMODE = .RDWR },
        0,
    );
    testing.expectEqual(.SUCCESS, linux.errno(fd)) catch unreachable;
    return @intCast(fd);
}

/// Open the base directory.
fn openBaseDir() linux.fd_t {
    const fd = linux.openat(
        linux.AT.FDCWD,
        Test.base_dir,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true },
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
