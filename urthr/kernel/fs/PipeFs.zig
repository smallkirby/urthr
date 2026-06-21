//! Pipe filesystem.
//!
//! Anonymous pseudo-filesystem backing kernel pipe objects.
//!
//! Not mounted in the VFS tree.

const Self = @This();

/// Size in bytes of the pipe ring buffer in bytes.
const buf_size = 4096;

/// Memory allocator.
allocator: Allocator,

/// Pair of files of a pipe.
pub const PipePair = struct {
    /// Read-end of the pipe.
    read: *fs.File,
    /// Write-end of the pipe.
    write: *fs.File,
};

/// Initialize a pipe filesystem instance.
pub fn init(allocator: Allocator) error{OutOfMemory}!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
    };

    return self;
}

/// Pipe-specific inode implementation.
const InodeImpl = struct {
    /// Common part of the inode.
    common: fs.Inode,

    /// Ring buffer data.
    data: [buf_size]u8 = undefined,
    /// Index of the next byte to read.
    read_pos: usize = 0,
    /// Number of bytes currently buffered.
    buf_len: usize = 0,

    /// Lock protecting all fields below.
    lock: SpinLock = .{},
    /// Signaled when data becomes available.
    rcv: CondVar = .{},
    /// Signaled when buffer space becomes available.
    wcv: CondVar = .{},

    /// Number of open read-end file objects.
    readers: usize = 1,
    /// Number of open write-end file objects.
    writers: usize = 1,

    /// Memory allocator.
    allocator: Allocator,

    pub fn from(inode: *fs.Inode) *InodeImpl {
        return @fieldParentPtr("common", inode);
    }

    /// Copy bytes out of the ring buffer.
    pub fn read(self: *InodeImpl, out: []u8) usize {
        rtt.expect(self.lock.isLocked());

        const n = @min(out.len, self.buf_len);
        for (out[0..n], 0..) |*b, i| {
            b.* = self.data[(self.read_pos + i) % buf_size];
        }
        self.read_pos = (self.read_pos + n) % buf_size;
        self.buf_len -= n;

        return n;
    }

    /// Copy bytes into the ring buffer.
    ///
    /// If the buffer is full, only a partial write is performed.
    pub fn write(self: *InodeImpl, data: []const u8) usize {
        rtt.expect(self.lock.isLocked());

        const space = buf_size - self.buf_len;
        const n = @min(data.len, space);
        const write_pos = (self.read_pos + self.buf_len) % buf_size;
        for (data[0..n], 0..) |b, i| {
            self.data[(write_pos + i) % buf_size] = b;
        }
        self.buf_len += n;

        return n;
    }

    /// Check if the ring buffer is empty.
    pub fn isEmpty(self: *InodeImpl) bool {
        rtt.expect(self.lock.isLocked());
        return self.buf_len == 0;
    }

    /// Check if the ring buffer is full.
    pub fn isFull(self: *InodeImpl) bool {
        rtt.expect(self.lock.isLocked());
        return self.buf_len == buf_size;
    }
};

/// Per-open context.
const FileCtx = struct {
    /// Pointer to the pipe inode.
    pipe: *InodeImpl,
    /// Which end of the pipe.
    end: End,

    const End = enum {
        /// Read-end of the pipe.
        read,
        /// Write-end of the pipe.
        write,
    };
};

/// Allocate a new pipe and return its read and write file objects.
pub fn createPipe(self: *Self) fs.Error!PipePair {
    const allocator = self.allocator;

    // Initialize the pipe inode.
    const pipe = try allocator.create(InodeImpl);
    errdefer allocator.destroy(pipe);
    pipe.* = .{
        .common = .{
            .number = 0,
            .size = 0,
            .ftype = .regular,
            .iops = pipe_iops,
            .fops = undefined,
        },
        .allocator = allocator,
    };

    // Create read- and write-end disconnected dentries.
    const rdentry = try fs.Dentry.create(
        "",
        &pipe.common,
        null,
        allocator,
    );
    errdefer rdentry.unref();
    pipe.common.ref();

    const wdentry = try fs.Dentry.create(
        "",
        &pipe.common,
        null,
        allocator,
    );
    errdefer wdentry.unref();
    pipe.common.ref();

    // Create pipe instance context for read- and write-end files.
    const rctx = try allocator.create(FileCtx);
    errdefer allocator.destroy(rctx);
    rctx.* = .{ .pipe = pipe, .end = .read };

    const wctx = try allocator.create(FileCtx);
    errdefer allocator.destroy(wctx);
    wctx.* = .{ .pipe = pipe, .end = .write };

    // Create read-end file.
    const read_file = try allocator.create(fs.File);
    errdefer allocator.destroy(read_file);
    read_file.* = .{
        .path = .{ .dentry = rdentry, .mount = null },
        .offset = 0,
        .ops = read_fops,
        .ctx = rctx,
        .allocator = allocator,
    };
    read_file.ref();

    // Create write-end file.
    const write_file = try allocator.create(fs.File);
    errdefer allocator.destroy(write_file);
    write_file.* = .{
        .path = .{ .dentry = wdentry, .mount = null },
        .offset = 0,
        .ops = write_fops,
        .ctx = wctx,
        .allocator = allocator,
    };
    write_file.ref();

    return .{ .read = read_file, .write = write_file };
}

// =============================================================
// Inode vtable
// =============================================================

const pipe_iops = fs.Inode.Ops{
    .lookup = &iLookup,
    .deinit = &iDeinit,
};

fn iLookup(_: *fs.Inode, _: []const u8) fs.Error!?*fs.Inode {
    // No FS hierarchy.
    return null;
}

fn iDeinit(inode: *fs.Inode) void {
    const pipe = InodeImpl.from(inode);
    pipe.allocator.destroy(pipe);
}

// =============================================================
// File vtables
// =============================================================

const read_fops = fs.File.Ops{
    .open = &fOpen,
    .iterate = &fIterate,
    .read = &frRead,
    .write = null,
    .close = &fClose,
    .poll = &frPoll,
};

const write_fops = fs.File.Ops{
    .open = &fOpen,
    .iterate = &fIterate,
    .read = &fwRead,
    .write = &frWrite,
    .close = &fClose,
    .poll = &fwPoll,
};

fn fOpen(_: *fs.Inode, _: Allocator) fs.Error!*anyopaque {
    @panic("pipe: open() must not be called.");
}

fn fIterate(_: *fs.File.Iterator, _: Allocator) fs.Error!?fs.File.IterResult {
    return null;
}

/// Read from write-end.
fn fwRead(_: *fs.File, _: []u8, _: usize) fs.Error!usize {
    // Read from write-end is not supported.
    return fs.Error.Unsupported;
}

/// Read from read-end.
fn frRead(file: *fs.File, buf: []u8, _: usize) fs.Error!usize {
    const ctx: *FileCtx = @ptrCast(@alignCast(file.ctx));
    const pipe = ctx.pipe;

    const ie = pipe.lock.lockDisableIrq();
    defer pipe.lock.unlockRestoreIrq(ie);

    while (pipe.isEmpty()) {
        if (pipe.writers == 0) return 0; // EOF
        pipe.rcv.wait(&pipe.lock);
    }

    const n = pipe.read(buf);
    pipe.wcv.signal();
    return n;
}

/// Write to write-end.
fn frWrite(file: *fs.File, buf: []const u8, _: usize) fs.Error!usize {
    const ctx: *FileCtx = @ptrCast(@alignCast(file.ctx));
    const pipe = ctx.pipe;

    const ie = pipe.lock.lockDisableIrq();
    defer pipe.lock.unlockRestoreIrq(ie);

    while (pipe.isFull()) {
        if (pipe.readers == 0) return fs.Error.BrokenPipe;
        pipe.wcv.wait(&pipe.lock);
    }

    if (pipe.readers == 0) {
        return fs.Error.BrokenPipe;
    }

    const n = pipe.write(buf);
    pipe.rcv.signal();
    return n;
}

fn fClose(context: *anyopaque, allocator: Allocator) void {
    const ctx: *FileCtx = @ptrCast(@alignCast(context));
    const pipe = ctx.pipe;

    const ie = pipe.lock.lockDisableIrq();
    switch (ctx.end) {
        .read => {
            pipe.readers -= 1;
            if (pipe.readers == 0) pipe.wcv.broadcast();
        },
        .write => {
            pipe.writers -= 1;
            if (pipe.writers == 0) pipe.rcv.broadcast();
        },
    }
    pipe.lock.unlockRestoreIrq(ie);

    allocator.destroy(ctx);
}

/// Poll on read-end.
fn frPoll(file: *fs.File) fs.Error!fs.PollResult {
    const ctx: *FileCtx = @ptrCast(@alignCast(file.ctx));
    const pipe = ctx.pipe;

    pipe.lock.lock();
    defer pipe.lock.unlock();

    return .{
        .events = .{
            .in = pipe.buf_len > 0 or pipe.writers == 0,
        },
    };
}

/// Poll on write-end.
fn fwPoll(file: *fs.File) fs.Error!fs.PollResult {
    const ctx: *FileCtx = @ptrCast(@alignCast(file.ctx));
    const pipe = ctx.pipe;

    pipe.lock.lock();
    defer pipe.lock.unlock();

    return .{ .events = .{
        .out = pipe.buf_len < buf_size and pipe.readers > 0,
    } };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const fs = urd.fs;
const SpinLock = urd.sync.SpinLock;
const CondVar = urd.sync.CondVar;
