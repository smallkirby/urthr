// =============================================================
// seek

/// syscall: lseek
pub fn sysLseek(fd: i32, offset: i64, whence: Whence) ReturnType {
    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();

    const w: fs.File.Whence = switch (whence) {
        .set => .set,
        .cur => .cur,
        .end => .end,
        else => return .err(.inval),
    };

    const new_offset = file.seek(offset, w) catch |err| return switch (err) {
        fs.Error.IllegalSeek => .err(.spipe),
        else => .err(.inval),
    };

    return .success(@intCast(new_offset));
}

const Whence = enum(i32) {
    /// Offset is set to offset bytes.
    set = 0,
    /// Offset is set to its current location plus offset bytes.
    cur = 1,
    /// Offset is set to the size of the file plus offset bytes.
    end = 2,

    _,
};

// =============================================================
// write

/// syscall: write
pub fn sysWrite(fd: i32, buf: usize, count: usize) ReturnType {
    return scalarXfer(.write, fd, buf, count, null);
}

/// syscall: pwrite64
pub fn sysPwrite64(fd: i32, buf: usize, count: usize, pos: i64) ReturnType {
    if (pos < 0) {
        return .err(.inval);
    }

    return scalarXfer(.write, fd, buf, count, @intCast(pos));
}

/// syscall: writev
pub fn sysWritev(fd: i32, iov: ?[*]const Iovec, iovcnt: usize) ReturnType {
    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();

    return vectoredXfer(.write, file, iov, iovcnt, null);
}

/// syscall: pwritev
pub fn sysPwritev(fd: i32, iov: ?[*]const Iovec, iovcnt: usize, pos_l: u64, _: u32) ReturnType {
    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();

    return vectoredXfer(.write, file, iov, iovcnt, @intCast(pos_l));
}

// =============================================================
// read

/// syscall: read
pub fn sysRead(fd: i32, buf: usize, count: usize) ReturnType {
    return scalarXfer(.read, fd, buf, count, null);
}

/// syscall: pread64
pub fn sysPread64(fd: i32, buf: usize, count: usize, pos: i64) ReturnType {
    if (pos < 0) {
        return .err(.inval);
    }

    return scalarXfer(.read, fd, buf, count, @intCast(pos));
}

/// syscall: readv
pub fn sysReadv(fd: i32, iov: ?[*]const Iovec, iovcnt: usize) ReturnType {
    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();

    return vectoredXfer(.read, file, iov, iovcnt, null);
}

/// syscall: preadv
pub fn sysPreadv(fd: i32, iov: ?[*]const Iovec, iovcnt: usize, pos_l: u64, _: u32) ReturnType {
    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();

    return vectoredXfer(.read, file, iov, iovcnt, @intCast(pos_l));
}

// =============================================================
// truncate

/// syscall: ftruncate
pub fn sysFtruncate(fd: i32, length: i64) ReturnType {
    if (length < 0) {
        return .err(.inval);
    }

    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();

    file.truncate(@intCast(length)) catch |err| return switch (err) {
        fs.Error.Unsupported => .err(.inval),
        else => writeError(err),
    };

    return .success(0);
}

// =============================================================
// copy

/// syscall: sendfile
pub fn sysSendfile(out_fd: i32, in_fd: i32, offset: ?*align(1) i64, count: usize) ReturnType {
    const out_file = getFile(out_fd) orelse return .err(.badf);
    defer out_file.unref();
    const in_file = getFile(in_fd) orelse return .err(.badf);
    defer in_file.unref();

    // Check the access modes.
    if (!in_file.access.readable or !out_file.access.writable) {
        return .err(.badf);
    }
    if (offset != null and !in_file.seekable) {
        return .err(.spipe);
    }

    // Load the current position for the input file.
    var pos = loadPos(offset, in_file.offset) catch |err| {
        return offsetError(err);
    };

    // Perform the file copy operation.
    const result = copyFileLoop(
        in_file,
        out_file,
        &pos,
        null,
        count,
    );

    // Update the input file's position.
    storePos(offset, in_file, pos) catch return .err(.fault);

    return result.map();
}

/// syscall: copy_file_range
pub fn sysCopyFileRange(
    fd_in: i32,
    off_in: ?*align(1) i64,
    fd_out: i32,
    off_out: ?*align(1) i64,
    len: usize,
    flags: u32,
) ReturnType {
    if (flags != 0) {
        return .err(.inval); //  Flags are reserved for future use.
    }

    const file_in = getFile(fd_in) orelse return .err(.badf);
    defer file_in.unref();
    const file_out = getFile(fd_out) orelse return .err(.badf);
    defer file_out.unref();

    // Check the access modes.
    if (!file_in.access.readable or !file_out.access.writable) {
        return .err(.badf);
    }
    if (file_out.status_flags.append) {
        return .err(.badf);
    }

    // Offsets can be specified only for seekable files.
    if (off_in != null and !file_in.seekable) {
        return .err(.badf);
    }
    if (off_out != null and !file_out.seekable) {
        return .err(.badf);
    }

    // Only regular files can be copied.
    if (file_in.getType() == .directory or file_out.getType() == .directory) {
        return .err(.isdir);
    }
    if (file_in.getType() != .regular or file_out.getType() != .regular) {
        return .err(.inval);
    }

    // Load the current positions for the input and output files.
    var pos_in = loadPos(off_in, file_in.offset) catch |err| {
        return offsetError(err);
    };
    var pos_out = loadPos(off_out, file_out.offset) catch |err| {
        return offsetError(err);
    };

    // Reject overlapping ranges within the same file.
    if (file_in.path.dentry.getInode() == file_out.path.dentry.getInode() and
        pos_in < pos_out + len and pos_out < pos_in + len)
    {
        return .err(.inval);
    }

    // Perform the file copy operation.
    const result = copyFileLoop(
        file_in,
        file_out,
        &pos_in,
        &pos_out,
        len,
    );

    // Update the positions of the input and output files.
    storePos(off_in, file_in, pos_in) catch return .err(.fault);
    storePos(off_out, file_out, pos_out) catch return .err(.fault);

    return result.map();
}

/// Error of reading a user-specified offset.
const OffsetError = error{ Fault, Invalid };

/// Convert `OffsetError` to syscall return type.
fn offsetError(err: OffsetError) ReturnType {
    return .err(switch (err) {
        error.Fault => .fault,
        error.Invalid => .inval,
    });
}

/// Read the starting position given by an optional user pointer.
///
/// Returns the default value when no user pointer is provided.
fn loadPos(uptr: ?*align(1) i64, default: usize) OffsetError!usize {
    const ptr = uptr orelse return default;
    const off = uaccess.getUser(i64, ptr) catch return error.Fault;

    return if (off >= 0) @intCast(off) else error.Invalid;
}

/// Write back the position after a transfer.
///
/// When the user pointer is given, the file's own offset is not updated.
fn storePos(uptr: ?*align(1) i64, file: *fs.File, pos: usize) !void {
    if (uptr) |p| {
        try uaccess.putUser(i64, p, @intCast(pos));
    } else {
        file.offset = pos;
    }
}

const CopyLoopResult = struct {
    /// Bytes successfully copied.
    total: usize,
    /// Pending error.
    err: ?ReturnType,

    fn map(self: CopyLoopResult) ReturnType {
        return if (self.err) |err|
            progressOr(self.total, err)
        else
            .success(@bitCast(self.total));
    }
};

/// Copy up to `count` bytes from `in_file` at `pos_in` to `out_file`.
///
/// The output file is written at `pos_out` if provided, otherwise at its own offset.
///
/// TODO: should be zero-copy.
fn copyFileLoop(
    in_file: *fs.File,
    out_file: *fs.File,
    pos_in: *usize,
    pos_out: ?*usize,
    count: usize,
) CopyLoopResult {
    var buf: [bounce_size]u8 = undefined;
    var total: usize = 0;
    while (total < count) {
        // Read from the input file.
        const chunk = @min(count - total, buf.len);
        const nread = in_file.pread(
            buf[0..chunk],
            pos_in.*,
        ) catch |err| return .{
            .total = total,
            .err = maperror(err),
        };
        if (nread.len == 0) break;

        // Write to the output file.
        const written = if (pos_out) |p|
            out_file.pwrite(nread, p.*)
        else
            out_file.write(nread);
        const nwritten = written catch |err| return .{
            .total = total,
            .err = writeError(err),
        };

        pos_in.* += nwritten;
        if (pos_out) |p| p.* += nwritten;
        total += nwritten;

        if (nwritten < nread.len) break;
    }

    return .{ .total = total, .err = null };
}

// =============================================================
// Helpers

/// Size in bytes of the bounce buffer.
const bounce_size = 4096;

/// Vectorized I/O struct.
const Iovec = extern struct {
    /// Starting address.
    base: [*]u8,
    /// Number of bytes to transfer.
    len: usize,
};

/// Direction of a transfer between user memory and a file.
const Direction = enum {
    read,
    write,

    /// Convert an I/O error to syscall return type.
    fn errmap(self: Direction, err: Error) ReturnType {
        return switch (self) {
            .read => maperror(err),
            .write => writeError(err),
        };
    }
};

/// Result of a transfer between user memory and a file.
const XferResult = union(enum) {
    /// All requested bytes were transferred.
    full: usize,
    /// Fewer than requested were transferred.
    partial: usize,
    /// Invalid user address.
    fault,
    /// I/O error occurred.
    io: fs.Error,

    /// Result of a transfer that failed with the error of a chunk transfer.
    fn fromError(err: ChunkError) XferResult {
        return switch (err) {
            error.Fault => .fault,
            else => |e| .{ .io = e },
        };
    }

    /// Result of a transfer that stopped at `done` bytes because of a failure.
    ///
    /// `failure` is reported only if no byte has been transferred.
    fn partialOr(done: usize, failure: XferResult) XferResult {
        return if (done != 0) .{ .partial = done } else failure;
    }

    /// Result of a transfer that ended after `done` out of `count` bytes without failure.
    fn finished(done: usize, count: usize) XferResult {
        return if (done == count) .{ .full = done } else .{ .partial = done };
    }
};

/// Error of transferring a single chunk.
const ChunkError = fs.Error || error{Fault};

/// Transfer the data of a file to and from the single user buffer.
///
/// When `pos` is not null, the transfer starts at that offset without changing file offset.
fn scalarXfer(
    comptime dir: Direction,
    fd: i32,
    buf: usize,
    count: usize,
    pos: ?usize,
) ReturnType {
    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();

    return switch (xferUser(dir, file, buf, count, pos)) {
        .full, .partial => |n| .success(@bitCast(n)),
        .fault => .err(.fault),
        .io => |err| dir.errmap(err),
    };
}

/// Transfer the data of a file to and from the user buffers described by the I/O vector.
///
/// When `pos` is not null, the transfer starts at that offset without changing file offset.
fn vectoredXfer(
    comptime dir: Direction,
    file: *fs.File,
    iov: ?[*]const Iovec,
    iovcnt: usize,
    pos: ?usize,
) ReturnType {
    if (iovcnt == 0) {
        return .success(0);
    }
    const iov_addr = @intFromPtr(iov orelse return .err(.fault));

    var cur_pos = pos;
    var total: usize = 0;
    for (0..iovcnt) |i| {
        // Load an I/O vector from user.
        const vec = uaccess.getUser(
            Iovec,
            iov_addr + i * @sizeOf(Iovec),
        ) catch return progressOr(total, .err(.fault));

        // Transfer the data of this vector.
        switch (xferUser(
            dir,
            file,
            @intFromPtr(vec.base),
            vec.len,
            cur_pos,
        )) {
            .full => |n| {
                total += n;
                if (cur_pos) |*p| {
                    p.* = std.math.add(usize, p.*, n) catch break;
                }
            },
            .partial => |n| return .success(@bitCast(total + n)),
            .fault => return progressOr(total, .err(.fault)),
            .io => |err| return progressOr(total, dir.errmap(err)),
        }
    }

    return .success(@bitCast(total));
}

/// Transfer up to `count` bytes between user memory at `uaddr` and `file` over the bounce buffer.
///
/// When the file position is provided, the file's own position is not advanced.
///
/// TODO: should not use bounce buffer to avoid extra memory copy overhead.
fn xferUser(
    comptime dir: Direction,
    file: *fs.File,
    uaddr: usize,
    count: usize,
    pos: ?usize,
) XferResult {
    if (count == 0) {
        return .{ .full = 0 };
    }
    if (!uaccess.accessOk(uaddr, count)) {
        return .fault;
    }

    var buf: [bounce_size]u8 = undefined;
    var done: usize = 0;
    while (done < count) {
        const want = @min(count - done, buf.len);

        var chunk_pos: ?usize = null;
        if (pos) |p| {
            chunk_pos = std.math.add(usize, p, done) catch {
                return .{ .io = fs.Error.InvalidArgument };
            };
        }

        const n = switch (dir) {
            .read => readChunk(
                file,
                buf[0..want],
                uaddr + done,
                chunk_pos,
            ),
            .write => writeChunk(
                file,
                buf[0..want],
                uaddr + done,
                chunk_pos,
            ),
        } catch |err| {
            return .partialOr(done, .fromError(err));
        };
        done += n;

        // A short transfer means EOF for a read.
        if (n < want or (dir == .read and !file.seekable)) {
            return .finished(done, count);
        }
    }

    return .{ .full = done };
}

/// Read a chunk from `file` through `buf`, and copy it to user memory at `uaddr`.
///
/// Returns the number of bytes read.
fn readChunk(file: *fs.File, buf: []u8, uaddr: usize, pos: ?usize) ChunkError!usize {
    const data = if (pos) |p|
        try file.pread(buf, p)
    else
        try file.read(buf);

    if (data.len != 0) {
        uaccess.copyToUser(uaddr, data) catch return error.Fault;
    }

    return data.len;
}

/// Copy a chunk from user memory at `uaddr` to `buf`, and write it to `file`.
///
/// Returns the number of bytes written.
fn writeChunk(file: *fs.File, buf: []u8, uaddr: usize, pos: ?usize) ChunkError!usize {
    uaccess.copyFromUser(buf, uaddr) catch return error.Fault;

    return if (pos) |p|
        file.pwrite(buf, p)
    else
        file.write(buf);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const fs = urd.fs;
const uaccess = urd.uaccess;
const ReturnType = urd.syscall.ReturnType;

const helper = @import("helper.zig");
const Error = helper.Error;
const maperror = helper.maperror;
const writeError = helper.writeError;
const getFile = helper.getFile;
const progressOr = helper.progressOr;
