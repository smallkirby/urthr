//! Helpers shared by the POSIX filesystem syscalls.

/// File descriptor representing the current working directory.
pub const cwd_fd: i32 = -100;

/// Maximum byte length of a path including NULL-terminator copied in from user space.
pub const path_max = 4096;

/// POSIX FS error.
pub const Error = error{ BadFileDescriptor, Fault } || fs.Error;

/// Kernel buffer for a path string copied from user space.
pub const UserPath = struct {
    buf: [path_max]u8 = undefined,

    /// Copy a NULL-terminated path from user space.
    ///
    /// Returns null if the user address is invalid.
    pub fn copyFrom(self: *UserPath, user: [*:0]const u8) ?[]const u8 {
        return urd.uaccess.copyString(
            &self.buf,
            @intFromPtr(user),
        ) catch null;
    }
};

/// Convert a filesystem error to syscall return type.
pub fn maperror(err: anyerror) ReturnType {
    return .err(switch (err) {
        Error.WouldBlock => .again,
        Error.BrokenPipe => .pipe,
        Error.NotDirectory => .notdir,
        Error.NotFile => .isdir,
        Error.NotFound => .noent,
        Error.NotEmpty => .notempty,
        Error.AlreadyExists => .exist,
        Error.AlreadyMounted, Error.Busy => .busy,
        Error.NoSpace => .nospace,
        Error.BadAccess, Error.BadFileDescriptor => .badf,
        Error.Fault => .fault,
        Error.IllegalSeek => .spipe,
        Error.InvalidArgument => .inval,
        Error.CrossDevice => .xdev,
        Error.Unsupported => .perm,
        Error.Loop => .loop,
        else => .io,
    });
}

/// Reports `n` transferred bytes as success if non-zero.
/// Otherwise returns the pending failure.
pub fn progressOr(n: usize, failure: ReturnType) ReturnType {
    return if (n != 0) .success(@bitCast(n)) else failure;
}

/// Convert write-related error to syscall return type.
pub fn writeError(e: Error) ReturnType {
    return switch (e) {
        Error.NotFile => .err(.badf),
        else => maperror(e),
    };
}

/// Convert a file descriptor to the index into the fd table.
///
/// Returns null if the fd is not valid.
pub fn fdindex(fd: i32) ?usize {
    return std.math.cast(usize, fd);
}

/// Get a file from the given file descriptor.
///
/// The caller owns the returned reference.
///
/// Returns null if `fd` is not an open file descriptor.
pub fn getFile(fd: i32) ?*fs.File {
    const fdidx = fdindex(fd) orelse return null;
    return sched.getCurrent().fs.fdtbl.get(fdidx) catch null;
}

// =============================================================
// at- family helpers

/// Describes a file resolved via at-style path.
pub const ResolveFile = struct {
    /// Resolved file.
    file: *fs.File,

    // De-initialize the file reference.
    pub fn deinit(self: ResolveFile) void {
        self.file.unref();
    }

    /// Resolve the target file for at-style syscall.
    pub fn at(dirfd: i32, pathname: []const u8, flags: AtFlags, allocator: Allocator) Error!ResolveFile {
        if (flags.empty_path and pathname.len == 0) {
            const file = getFile(dirfd) orelse return Error.BadFileDescriptor;
            return .{ .file = file };
        }

        return .{ .file = try openFileAt(
            dirfd,
            pathname,
            .{},
            allocator,
            !flags.symlink_nofollow,
        ) };
    }

    /// Resolve the target file for at-style syscall from a path in user space.
    pub fn atUser(dirfd: i32, pathname: [*:0]const u8, flags: AtFlags, allocator: Allocator) Error!ResolveFile {
        var upath: UserPath = .{};
        const path = upath.copyFrom(pathname) orelse return Error.Fault;

        return at(dirfd, path, flags, allocator);
    }
};

/// Get the file mode to create a file with, applying the umask of the current thread.
pub fn effectiveMode(mode: Mode) fs.FileMode {
    return sched.getCurrent().fs.info.umask.apply(mode.to());
}

/// Resolve the base directory under which a relative `pathname` should be looked up.
///
/// Returns null when `pathname` is absolute.
/// In that case callers should use the root-relative FS function instead of the -at family.
///
/// Caller owns the returned path.
fn resolveBaseDir(dirfd: i32, pathname: []const u8) Error!?fs.Path {
    if (std.fs.path.isAbsolute(pathname)) {
        return null;
    }

    const cur = sched.getCurrent();
    if (dirfd == cwd_fd) {
        return cur.fs.info.getCwd();
    }

    const dir = getFile(dirfd) orelse return Error.BadFileDescriptor;
    defer dir.unref();
    return dir.path.get();
}

/// Call `at_fn` with the base directory for a relative `pathname`.
fn callAt(
    comptime at_fn: anytype,
    comptime plain_fn: anytype,
    dirfd: i32,
    pathname: []const u8,
    args: anytype,
) CallResult(at_fn) {
    if (try resolveBaseDir(dirfd, pathname)) |base| {
        // Try at- function first.
        defer base.put();
        return @call(.auto, at_fn, .{ base, pathname } ++ args);
    } else {
        // Then, use the plain function.
        return @call(.auto, plain_fn, .{pathname} ++ args);
    }
}

fn CallResult(comptime f: anytype) type {
    const ret = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    return Error!@typeInfo(ret).error_union.payload;
}

pub fn openFileAt(dirfd: i32, pathname: []const u8, access: AccessMode, allocator: Allocator, follow: bool) Error!*fs.File {
    return callAt(fs.openAt, fs.open, dirfd, pathname, .{ access, allocator, follow });
}

pub fn createFileAt(dirfd: i32, pathname: []const u8, mode: fs.FileMode, access: AccessMode, allocator: Allocator) Error!*fs.File {
    return callAt(fs.createAt, fs.create, dirfd, pathname, .{ mode, access, allocator });
}

pub fn mkdirFileAt(dirfd: i32, pathname: []const u8, mode: fs.FileMode, allocator: Allocator) Error!void {
    return callAt(fs.mkdirAt, fs.mkdir, dirfd, pathname, .{ mode, allocator });
}

pub fn readlinkFileAt(dirfd: i32, pathname: []const u8, buf: []u8, allocator: Allocator) Error!usize {
    return callAt(fs.readlinkAt, fs.readlink, dirfd, pathname, .{ buf, allocator });
}

pub fn unlinkFileAt(dirfd: i32, pathname: []const u8, allocator: Allocator) Error!void {
    return callAt(fs.unlinkAt, fs.unlink, dirfd, pathname, .{allocator});
}

pub fn rmdirFileAt(dirfd: i32, pathname: []const u8, allocator: Allocator) Error!void {
    return callAt(fs.rmdirAt, fs.rmdir, dirfd, pathname, .{allocator});
}

pub fn symlinkFileAt(dirfd: i32, pathname: []const u8, target: []const u8, allocator: Allocator) Error!void {
    const plain = struct {
        fn symlink(linkpath: []const u8, tgt: []const u8, a: Allocator) fs.Error!void {
            return fs.symlink(tgt, linkpath, a);
        }
    }.symlink;

    return callAt(fs.symlinkAt, plain, dirfd, pathname, .{ target, allocator });
}

/// File information for a rename operation.
const RenameOperand = struct {
    /// Directory containing the file to rename.
    dir: fs.Path,
    /// Basename of the file to rename.
    name: []const u8,

    fn deinit(self: RenameOperand) void {
        self.dir.put();
    }
};

/// Get a operand for a rename operation.
fn resolveRenameOperand(
    dirfd: i32,
    pathname: []const u8,
    allocator: Allocator,
) Error!RenameOperand {
    if (try resolveBaseDir(dirfd, pathname)) |base| {
        return .{ .dir = base, .name = pathname };
    } else {
        const basename = std.fs.path.basenamePosix(pathname);
        if (basename.len == 0) {
            return fs.Error.InvalidArgument;
        }

        const dirname = std.fs.path.dirnamePosix(pathname) orelse "/";
        const dir = try fs.resolve(dirname, allocator, true);
        return .{ .dir = dir, .name = basename };
    }
}

/// Rename or move a file relative to the given directory file descriptors.
pub fn renameFileAt(
    olddirfd: i32,
    oldpath: []const u8,
    newdirfd: i32,
    newpath: []const u8,
    noreplace: bool,
    allocator: Allocator,
) Error!void {
    const old_op = try resolveRenameOperand(olddirfd, oldpath, allocator);
    defer old_op.deinit();
    const new_op = try resolveRenameOperand(newdirfd, newpath, allocator);
    defer new_op.deinit();

    return fs.renameAt(
        old_op.dir,
        old_op.name,
        new_op.dir,
        new_op.name,
        noreplace,
        allocator,
    );
}

// =============================================================
// Imports
// =============================================================

const abi = @import("abi.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
const urd = @import("urthr");
const fs = urd.fs;
const sched = urd.sched;
const AccessMode = fs.File.AccessMode;
const ReturnType = urd.syscall.ReturnType;
const AtFlags = abi.AtFlags;
const Mode = abi.Mode;
