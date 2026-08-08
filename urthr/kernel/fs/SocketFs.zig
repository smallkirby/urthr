//! Socket filesystem.
//!
//! Not mounted in the VFS tree.
//!
//! This is a thin wrapper around protocol-specific socket implementation.

const Self = @This();

/// Operations a protocol module must provide to back a socket file.
pub const Backend = struct {
    /// Read data from the socket identified by `desc`.
    read: *const fn (desc: usize, buf: []u8, nonblock: bool) fs.Error!usize,
    /// Write data to the socket identified by `desc`.
    write: *const fn (desc: usize, buf: []const u8, nonblock: bool) fs.Error!usize,
    /// Return the current I/O readiness of the socket identified by `desc`.
    poll: *const fn (desc: usize) fs.PollEvents,
    /// Release the socket identified by `desc`.
    close: *const fn (desc: usize) void,
    /// Connect the socket identified by `desc` to the given remote endpoint.
    connect: *const fn (desc: usize, ip: net.ip.IpAddr, port: u16) fs.Error!void,
    /// Bind the socket identified by `desc` to the given local endpoint.
    bind: *const fn (desc: usize, ip: net.ip.IpAddr, port: u16) fs.Error!void,
};

/// Memory allocator.
allocator: Allocator,

/// Initialize a socket filesystem instance.
pub fn init(allocator: Allocator) error{OutOfMemory}!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
    };

    return self;
}

/// Create a new socket file wrapping the given protocol-specific descriptor.
///
/// The created socket is backed by the given protocol backend.
/// The backend can identify the socket instance by the given opaque descriptor.
pub fn createSocket(self: *Self, backend: *const Backend, desc: usize) fs.Error!*fs.File {
    const allocator = self.allocator;

    // Allocate inode.
    const inode = try allocator.create(InodeImpl);
    errdefer allocator.destroy(inode);
    inode.* = .{
        .common = .{
            .number = 0, // TODO
            .size = 0,
            .ftype = .socket,
            .iops = socket_iops,
            .fops = undefined,
        },
        .allocator = allocator,
    };

    // Allocate dentry and associate it with the inode.
    const dentry = try fs.Dentry.create(
        "",
        &inode.common,
        null,
        allocator,
    );
    errdefer dentry.unref();
    inode.common.ref();

    // Allocate file context and file object.
    const ctx = try allocator.create(FileCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{ .desc = desc, .backend = backend };

    const file = try allocator.create(fs.File);
    errdefer allocator.destroy(file);
    file.* = .{
        .path = .{ .dentry = dentry, .mount = null },
        .offset = 0,
        .access = .{},
        .seekable = false,
        .ops = socket_fops,
        .ctx = ctx,
        .allocator = allocator,
    };
    file.ref();

    return file;
}

/// Connect the given socket file to the given remote endpoint.
///
/// TODO: should not limit the address family to IPv4.
pub fn connect(file: *fs.File, ip: net.ip.IpAddr, port: u16) fs.Error!void {
    const ctx = try ctxFromFile(file);
    return ctx.backend.connect(ctx.desc, ip, port);
}

/// Bind the given socket file to the given local endpoint.
///
/// TODO: should not limit the address family to IPv4.
pub fn bind(file: *fs.File, ip: net.ip.IpAddr, port: u16) fs.Error!void {
    const ctx = try ctxFromFile(file);
    return ctx.backend.bind(ctx.desc, ip, port);
}

/// Options on how to shut down a socket connection.
pub const ShutdownOption = packed struct {};

/// Shut down the given socket file's underlying connection.
pub fn shutdown(file: *fs.File, _: ShutdownOption) fs.Error!void {
    const ctx = try ctxFromFile(file);
    ctx.backend.close(ctx.desc);
}

// =============================================================
// Inode implementation

/// Socket-specific inode implementation.
const InodeImpl = struct {
    /// Common part of the inode.
    common: fs.Inode,
    /// Memory allocator.
    allocator: Allocator,

    pub fn from(inode: *fs.Inode) *InodeImpl {
        return @fieldParentPtr("common", inode);
    }
};

/// Per-open file context.
const FileCtx = struct {
    /// Opaqueue protocol-specific descriptor.
    desc: usize,
    /// Pointer to the socket backend for the protocol.
    backend: *const Backend,
};

const socket_iops = fs.Inode.Ops{
    .lookup = &iLookup,
    .deinit = &iDeinit,
};

fn iLookup(_: *fs.Inode, _: []const u8) fs.Error!?*fs.Inode {
    return null;
}

fn iDeinit(inode: *fs.Inode) void {
    const impl = InodeImpl.from(inode);
    impl.allocator.destroy(impl);
}

/// Get the socket context of the given file.
fn ctxFromFile(file: *fs.File) fs.Error!*FileCtx {
    if (file.getType() != .socket) {
        return fs.Error.NotSocket;
    }
    return @ptrCast(@alignCast(file.ctx));
}

// =============================================================
// File vtable

const socket_fops = fs.File.Ops{
    .open = &fOpen,
    .iterate = &fIterate,
    .read = &fRead,
    .write = &fWrite,
    .close = &fClose,
    .poll = &fPoll,
};

fn fOpen(_: *fs.Inode, _: Allocator) fs.Error!*anyopaque {
    unreachable;
}

fn fIterate(_: *fs.File.Iterator, _: Allocator) fs.Error!?fs.File.IterResult {
    return null;
}

fn fRead(file: *fs.File, buf: []u8, _: usize) fs.Error!usize {
    const ctx: *FileCtx = @ptrCast(@alignCast(file.ctx));
    return ctx.backend.read(
        ctx.desc,
        buf,
        file.status_flags.nonblock,
    );
}

fn fWrite(file: *fs.File, buf: []const u8, _: usize) fs.Error!usize {
    const ctx: *FileCtx = @ptrCast(@alignCast(file.ctx));
    return ctx.backend.write(
        ctx.desc,
        buf,
        file.status_flags.nonblock,
    );
}

fn fClose(context: *anyopaque, allocator: Allocator) void {
    const ctx: *FileCtx = @ptrCast(@alignCast(context));
    ctx.backend.close(ctx.desc);
    allocator.destroy(ctx);
}

fn fPoll(file: *fs.File) fs.Error!fs.PollResult {
    const ctx: *FileCtx = @ptrCast(@alignCast(file.ctx));
    return .{ .events = ctx.backend.poll(ctx.desc) };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const urd = @import("urthr");
const fs = urd.fs;
const net = urd.net;
