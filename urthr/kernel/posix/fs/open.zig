// =============================================================
// open

/// syscall: openat
pub fn sysOpenAt(dirfd: i32, pathname: [*:0]const u8, flags: OpenFlags, mode: Mode) ReturnType {
    var upath: helper.UserPath = .{};
    const path = upath.copyFrom(pathname) orelse return .err(.fault);

    // Open or create the file.
    const file = resolveOpenFile(
        dirfd,
        path,
        flags,
        mode,
        urd.mem.bin,
    ) catch |err| return maperror(err);
    defer file.unref();

    // Check file type and flags.
    const ftype = file.getType();
    const writable = flags.wo or flags.rdwr;

    if (flags.directory and ftype != .directory) {
        return .err(.notdir);
    }
    if (ftype == .directory and writable) {
        return .err(.isdir);
    }
    if (flags.trunc and ftype == .regular and writable) {
        file.truncate(0) catch |err| switch (err) {
            fs.Error.Unsupported => {},
            else => return maperror(err),
        };
    }
    file.status_flags.set(.{
        .nonblock = flags.nonblock,
        .append = flags.append,
    });

    // Push the file into the fdtable.
    const cur = sched.getCurrent();
    const fd = cur.fs.fdtbl.allocAt(0, file, .{
        .cloexec = flags.cloexec,
    }) catch return .err(.mfile);

    return .success(@intCast(fd));
}

/// syscall: open
pub fn sysOpen(pathname: [*:0]const u8, flags: OpenFlags, mode: Mode) ReturnType {
    return sysOpenAt(helper.cwd_fd, pathname, flags, mode);
}

/// syscall: close
pub fn sysClose(fd: i32) ReturnType {
    const fdidx = fdindex(fd) orelse return .err(.badf);
    const cur = sched.getCurrent();
    cur.fs.fdtbl.close(fdidx) catch return .err(.badf);

    return .success(0);
}

// =============================================================
// dup

/// syscall: dup
pub fn sysDup(oldfd: i32) ReturnType {
    const file = getFile(oldfd) orelse return .err(.badf);
    defer file.unref();

    const cur = sched.getCurrent();
    const fd = cur.fs.fdtbl.alloc(file) catch return .err(.mfile);

    return .success(@intCast(fd));
}

/// syscall: dup2
pub fn sysDup2(oldfd: i32, newfd: i32) ReturnType {
    if (oldfd == newfd) {
        const file = getFile(oldfd) orelse return .err(.badf);
        file.unref();
        return .success(newfd);
    }
    return dupOnto(oldfd, newfd, .{});
}

/// syscall: dup3
pub fn sysDup3(oldfd: i32, newfd: i32, flags: OpenFlags) ReturnType {
    if (!flags.isFit(.{ .cloexec = true })) {
        return .err(.inval);
    }
    if (oldfd == newfd) {
        return .err(.inval);
    }

    return dupOnto(oldfd, newfd, .{
        .cloexec = flags.cloexec,
    });
}

/// Duplicate old fd onto new fd, closing already opened new fd if necessary.
fn dupOnto(oldfd: i32, newfd: i32, flags: FdFlags) ReturnType {
    const newidx = fdindex(newfd) orelse return .err(.badf);
    if (newidx >= fs.max_fds) {
        return .err(.badf);
    }

    const file = getFile(oldfd) orelse return .err(.badf);
    defer file.unref();

    const cur = sched.getCurrent();
    cur.fs.fdtbl.replaceAt(
        newidx,
        file,
        flags,
    ) catch return .err(.mfile);

    return .success(newfd);
}

// =============================================================
// pipe

/// syscall: pipe
pub fn sysPipe(pipefd: [*]i32) ReturnType {
    return sysPipe2(pipefd, .{});
}

/// syscall: pipe2
pub fn sysPipe2(pipefd: [*]i32, flags: OpenFlags) ReturnType {
    if (!flags.isFit(.{ .nonblock = true, .cloexec = true })) {
        return .err(.inval);
    }

    const cur = sched.getCurrent();
    const fd_flags = FdFlags{ .cloexec = flags.cloexec };

    // Create a pipe file pair.
    const pair = fs.createPipe() catch return .err(.nomem);
    defer {
        // Release the initial refs.
        pair.read.unref();
        pair.write.unref();
    }
    pair.read.status_flags.set(.{ .nonblock = flags.nonblock });
    pair.write.status_flags.set(.{ .nonblock = flags.nonblock });

    // Put the read- and write-end into the fd table.
    const rfd = cur.fs.fdtbl.allocAt(0, pair.read, fd_flags) catch {
        return .err(.mfile);
    };
    const wfd = cur.fs.fdtbl.allocAt(0, pair.write, fd_flags) catch {
        cur.fs.fdtbl.close(rfd) catch {};
        return .err(.mfile);
    };

    // Copy the created fd pair to user space.
    const fds = [2]i32{ @intCast(rfd), @intCast(wfd) };
    uaccess.copySliceToUser(i32, pipefd, &fds) catch {
        cur.fs.fdtbl.close(rfd) catch {};
        cur.fs.fdtbl.close(wfd) catch {};
        return .err(.fault);
    };

    return .success(0);
}

// =============================================================
// advise

/// syscall: fadvise64
///
/// Only DONTNEED has an effect.
pub fn sysFadvise64(fd: i32, offset: i64, len: i64, advice: Advice) ReturnType {
    if (offset < 0 or len < 0) {
        return .err(.inval);
    }

    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();

    if (!file.seekable) {
        return .err(.spipe);
    }

    switch (advice) {
        // Not supported.
        .normal,
        .random,
        .sequential,
        .willneed,
        .noreuse,
        => {},

        // Drop cache for the specified range.
        .dontneed => file.dropCache(
            @intCast(offset),
            @intCast(len),
        ) catch |e| return maperror(e),

        // Invalid advice.
        _ => return .err(.inval),
    }

    return .success(0);
}

/// Access pattern advice of fadvise64.
const Advice = enum(u32) {
    /// No advice to give.
    normal = 0,
    /// Expect to be accessed in random order.
    random = 1,
    /// Expect to be accessed sequentially.
    sequential = 2,
    /// Will be accessed in the near future.
    willneed = 3,
    /// Will not be accessed in the near future.
    dontneed = 4,
    /// Will be accessed only once.
    noreuse = 5,

    _,
};

// =============================================================
// Helpers
// =============================================================

/// Resolve the file to open honoring O_CREAT/O_EXCL semantics.
fn resolveOpenFile(
    dirfd: i32,
    pathname: []const u8,
    flags: OpenFlags,
    mode: Mode,
    allocator: Allocator,
) Error!*fs.File {
    const access: AccessMode = .{
        .readable = !flags.wo,
        .writable = flags.wo or flags.rdwr,
    };

    // When O_CREAT is not specified, just open the file.
    if (!flags.creat) return openFileAt(
        dirfd,
        pathname,
        access,
        allocator,
        true,
    );

    // When O_CREAT is specified, try to open first, then create if not existing.
    const file = openFileAt(
        dirfd,
        pathname,
        access,
        allocator,
        true,
    ) catch |err| {
        if (err != Error.NotFound) return err;

        return createFileAt(
            dirfd,
            pathname,
            effectiveMode(mode),
            access,
            allocator,
        ) catch |e| {
            // File has been concurrently created by another thread.
            return if (e == Error.AlreadyExists and !flags.excl) openFileAt(
                dirfd,
                pathname,
                access,
                allocator,
                true,
            ) else e;
        };
    };

    if (flags.excl) {
        file.unref();
        return Error.AlreadyExists;
    }

    return file;
}

// =============================================================
// Imports
// =============================================================

const abi = @import("abi.zig");
const helper = @import("helper.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
const urd = @import("urthr");
const fs = urd.fs;
const sched = urd.sched;
const uaccess = urd.uaccess;
const FdFlags = fs.FdTable.FdFlags;
const AccessMode = fs.File.AccessMode;
const ReturnType = urd.syscall.ReturnType;

const OpenFlags = abi.OpenFlags;
const Mode = abi.Mode;
const Error = helper.Error;
const maperror = helper.maperror;
const getFile = helper.getFile;
const fdindex = helper.fdindex;
const effectiveMode = helper.effectiveMode;
const openFileAt = helper.openFileAt;
const createFileAt = helper.createFileAt;
