//! POSIX compatibility layer for filesystem API.

/// File descriptor representing the current working directory.
const cwd_fd: usize = @bitCast(@as(i64, -100));

/// Vectorized I/O struct.
const Iovec = extern struct {
    /// Starting address.
    base: [*]u8,
    /// Number of bytes to transfer.
    len: usize,

    pub fn slice(self: Iovec) []u8 {
        return self.base[0..self.len];
    }
};

// =============================================================
// Open
// =============================================================

/// syscall: openat
pub fn sysOpenAt(dirfd: usize, pathname: [*:0]const u8, flags: OpenFlags, _: u32) ReturnType {
    const allocator = urd.mem.bin;
    const s = std.mem.span(pathname);

    const file = if (flags.creat)
        createFileAt(dirfd, s, allocator) catch |err|
            return mapOpenError(err)
    else
        openFileAt(dirfd, s, allocator) catch |err|
            return mapOpenError(err);

    if (flags.directory and file.getType() != .directory) {
        file.unref();
        return .err(.notdir);
    }

    const fd = sched.getCurrent().fs.fdtbl.alloc(file) catch
        return .err(.mfile);

    return .success(@bitCast(fd));
}

/// syscall: dup3
pub fn sysDup3(oldfd: usize, newfd: usize, flags: OpenFlags) ReturnType {
    if (oldfd == newfd) {
        return .err(.inval);
    }
    if (newfd >= urd.fs.max_fds) {
        return .err(.mfile);
    }

    const file = getFile(oldfd) catch return .err(.badf);
    const cur = sched.getCurrent();

    // Close newfd if already open.
    cur.fs.fdtbl.close(newfd) catch {};

    // Allocate a nearest available fd.
    const fd_flags = FdFlags{ .cloexec = flags.cloexec };
    _ = cur.fs.fdtbl.allocAt(
        newfd,
        file,
        fd_flags,
    ) catch return .err(.mfile);

    return .success(@intCast(newfd));
}

/// syscall: pipe2
pub fn sysPipe2(pipefd: [*]i32, flags: OpenFlags) ReturnType {
    const cur = sched.getCurrent();
    const fd_flags = FdFlags{ .cloexec = flags.cloexec };

    // Create a pipe file pair.
    const pair = urd.fs.createPipe() catch return .err(.nomem);
    defer {
        // Release the initial refs.
        pair.read.unref();
        pair.write.unref();
    }

    // Put the read- and write-end into the fd table.
    const rfd = cur.fs.fdtbl.allocAt(
        0,
        pair.read,
        fd_flags,
    ) catch {
        return .err(.mfile);
    };
    const wfd = cur.fs.fdtbl.allocAt(
        0,
        pair.write,
        fd_flags,
    ) catch {
        cur.fs.fdtbl.close(rfd) catch {};
        return .err(.mfile);
    };

    pipefd[0] = @intCast(rfd);
    pipefd[1] = @intCast(wfd);

    return .success(0);
}

/// syscall: close
pub fn sysClose(fd: usize) ReturnType {
    sched.getCurrent().fs.fdtbl.close(fd) catch {
        return .err(.badf);
    };

    return .success(0);
}

const OpenFlags = packed struct(i32) {
    /// Read-only.
    ro: bool = false,
    /// Write-only.
    wo: bool = false,
    /// Read and write.
    rdwr: bool = false,
    /// Reserved.
    _3: u3 = 0,
    /// Create file if it does not exist.
    creat: bool = false,
    /// Error if O_CREAT and the file exists.
    excl: bool = false,
    /// Even if the path refers to TTY, do not open it as a controlling TTY device.
    noctty: bool = false,
    /// Truncate file to zero length if it already exists.
    trunc: bool = false,
    /// Append mode.
    append: bool = false,
    /// Nonblocking mode if possible.
    nonblock: bool = false,
    /// Reserved.
    _12: u2 = 0,
    /// Fail unless the path resolves to a directory.
    directory: bool = false,
    /// Reserved.
    _15: u4 = 0,
    /// Enable close-on-exec flag.
    cloexec: bool = false,
    /// Reserved.
    _14: u12 = 0,
};

// =============================================================
// Seek
// =============================================================

/// syscall: lseek
pub fn sysLseek(fd: usize, offset: i64, whence: Whence) ReturnType {
    const file = getFile(fd) catch return .err(.badf);

    const new_offset: i64 = switch (whence) {
        .set => offset,
        .cur => @as(i64, @intCast(file.offset)) + offset,
        .end => @as(i64, @intCast(file.size())) + offset,
        else => return .err(.inval),
    };
    if (new_offset < 0) return .err(.inval);

    file.offset = @intCast(new_offset);
    return .success(@bitCast(new_offset));
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
// Write
// =============================================================

/// syscall: write
pub fn sysWrite(fd: usize, buf: usize, count: usize) ReturnType {
    const file = getFile(fd) catch return .err(.badf);
    const out = @as([*]const u8, @ptrFromInt(buf));
    const n = file.write(out[0..count]) catch |e| return writeErr(e);
    return .success(@bitCast(n));
}

/// syscall: writev
pub fn sysWritev(fd: usize, iov: [*]const Iovec, iovcnt: usize) ReturnType {
    const iovs = iov[0..iovcnt];
    const file = getFile(fd) catch return .err(.badf);

    var total: usize = 0;
    for (iovs) |v| {
        total += file.write(v.slice()) catch |e| return writeErr(e);
    }

    return .success(@bitCast(total));
}

/// syscall: pwritev
pub fn sysPwritev(fd: usize, iov: [*]const Iovec, iovcnt: usize, offset_l: u32, offset_h: u32) ReturnType {
    const offset = bits.concat(u64, offset_h, offset_l);
    if (offset != 0) {
        return .err(.nosys); // TODO: Not implemented.
    }

    const file = getFile(fd) catch return .err(.badf);
    const iovs = iov[0..iovcnt];

    var total: usize = 0;
    for (iovs) |v| {
        total += file.write(v.slice()) catch |e| return writeErr(e);
    }

    return .success(@bitCast(total));
}

fn writeErr(e: urd.fs.Error) ReturnType {
    return switch (e) {
        error.BrokenPipe => .err(.pipe),
        else => .err(.again),
    };
}

// =============================================================
// Read
// =============================================================

/// syscall: read
pub fn sysRead(fd: usize, buf: usize, count: usize) ReturnType {
    const file = getFile(fd) catch return .err(.badf);
    const out = @as([*]u8, @ptrFromInt(buf));
    const n = file.read(out[0..count]) catch return .err(.again);
    return .success(@bitCast(n.len));
}

// syscall: readv
pub fn sysReadv(fd: usize, iov: [*]const Iovec, iovcnt: usize) ReturnType {
    const iovs = iov[0..iovcnt];
    const file = getFile(fd) catch return .err(.badf);

    var total: usize = 0;
    for (iovs) |v| {
        const n = file.read(v.slice()) catch return .err(.again);
        total += n.len;
    }

    return .success(@bitCast(total));
}

/// syscall: preadv
pub fn sysPreadv(fd: usize, iov: [*]const Iovec, iovcnt: usize, offset_l: u32, offset_h: u32) ReturnType {
    const offset = bits.concat(u64, offset_h, offset_l);
    if (offset != 0) {
        return .err(.nosys); // TODO: Not implemented.
    }

    const file = getFile(fd) catch return .err(.badf);
    const iovs = iov[0..iovcnt];

    var total: usize = 0;
    for (iovs) |v| {
        const r = file.read(v.slice()) catch return .err(.again);
        total += r.len;
    }

    return .success(@bitCast(total));
}

// =============================================================
// Unlink
// =============================================================

// syscall: unlinkat
pub fn sysUnlinkAt(dirfd: usize, pathname: [*:0]const u8, _: i32) ReturnType {
    const allocator = urd.mem.bin;
    const s = std.mem.span(pathname);

    unlinkFileAt(dirfd, s, allocator) catch |err| return switch (err) {
        urd.fs.Error.NotFound => .err(.noent),
        urd.fs.Error.NotDirectory => .err(.notdir),
        urd.fs.Error.NotFile => .err(.isdir),
        urd.fs.Error.Unsupported => .err(.perm),
        error.BadFileDescriptor => .err(.badf),
        else => .err(.again),
    };

    return .success(0);
}

// =============================================================
// Stat
// =============================================================

/// syscall: fstat
pub fn sysFstat(fd: usize, statbuf: *Stat) ReturnType {
    const file = getFile(fd) catch return .err(.badf);

    statbuf.* = .{
        .st_dev = 0,
        .st_ino = file.path.dentry.inode.number,
        .st_mode = @bitCast(Mode.from(file)),
        .st_nlink = 1,
        .st_uid = 0,
        .st_gid = 0,
        .st_rdev = 0,
        .st_size = @intCast(file.size()),
        .st_blksize = 512,
        .st_blocks = @intCast(file.size() / 512),
    };

    return .success(0);
}

/// syscall: newfstatat
pub fn sysNewFstatAt(dirfd: usize, pathname: [*:0]const u8, statbuf: *Stat, flags: i32) ReturnType {
    _ = flags; // TODO: should be implemented.

    const allocator = urd.mem.bin;
    const s = std.mem.span(pathname);

    const file = openFileAt(dirfd, s, allocator) catch |err|
        return mapOpenError(err);

    statbuf.* = .{
        .st_dev = 0, // TODO
        .st_ino = file.path.dentry.inode.number,
        .st_mode = @bitCast(Mode.from(file)),
        .st_nlink = 1, // TODO
        .st_uid = 0, // TODO
        .st_gid = 0, // TODO
        .st_rdev = 0, // TODO
        .st_size = @intCast(file.size()),
        .st_blksize = 512,
        .st_blocks = @intCast(file.size() / 512),
    };

    return .success(0);
}

const Stat = extern struct {
    /// Device ID.
    st_dev: u64,
    /// Inode number.
    st_ino: u64,
    /// File mode.
    st_mode: u32,
    /// Number of hard links.
    st_nlink: u32,
    /// User ID of owner.
    st_uid: u32,
    /// Group ID of owner.
    st_gid: u32,
    /// Device ID (if special file).
    st_rdev: u64,
    /// Total size, in bytes.
    st_size: i64,
    /// Block size for filesystem I/O.
    st_blksize: i64,
    /// Number of 512B blocks allocated.
    st_blocks: i64,
};

/// File information including file type, access permission, and other special bits.
const Mode = packed struct(u32) {
    /// Access permission for others.
    other: Permission = .rwx,
    /// Access permission for a group.
    group: Permission = .rwx,
    /// Access permission for a user.
    user: Permission = .rwx,
    /// Special flags.
    flags: Flags = .none,
    /// File type.
    type: FileType,
    /// Reserved.
    _reserved: u16 = 0,

    pub const Flags = packed struct(u3) {
        /// Sticky bit.
        sticky: bool,
        /// Set Group ID.
        sgid: bool,
        /// Set User ID.
        suid: bool,

        pub const none = Flags{ .sticky = false, .sgid = false, .suid = false };
    };

    pub fn from(file: *const urd.fs.File) Mode {
        return Mode{ .type = .from(file.getType()) };
    }
};

/// Access permission for a single target.
const Permission = packed struct(u3) {
    read: bool,
    write: bool,
    exec: bool,

    pub const ro = Permission{ .read = true, .write = false, .exec = false };
    pub const rw = Permission{ .read = true, .write = true, .exec = false };
    pub const rx = Permission{ .read = true, .write = false, .exec = true };
    pub const rwx = Permission{ .read = true, .write = true, .exec = true };
};

/// File type.
const FileType = enum(u4) {
    /// Named pipe or FIFO.
    fifo = 1,
    /// Character special device.
    char = 2,
    /// Directory.
    dir = 4,
    /// Block special device.
    blk = 6,
    /// Regular file.
    regular = 8,
    /// Symbolic link.
    symlink = 10,
    /// Socket.
    socket = 12,

    _,

    /// Convert from Urthr FileType.
    pub fn from(ftype: urd.fs.FileType) FileType {
        return switch (ftype) {
            .regular => .regular,
            .directory => .dir,
        };
    }
};

// =============================================================
// getdents
// =============================================================

/// syscall: getdents64
pub fn sysGetDents64(fd: usize, ents: [*]u8, count: usize) ReturnType {
    const allocator = urd.mem.bin;
    const file = getFile(fd) catch return .err(.badf);
    if (file.getType() != .directory) {
        return .err(.notdir);
    }

    var consumed: usize = 0;
    var iter = file.iterator() catch return .err(.again);
    while (true) {
        const ent = (iter.next(allocator) catch return .err(.again)) orelse break;
        defer ent.deinit(allocator);

        const dent_size = DirEnt64.calcSize(ent.name);
        if (count - consumed < dent_size) {
            break;
        }

        DirEnt64.createCopy(
            ent.inum,
            .from(ent.type),
            ent.name,
            ents[consumed..][0..dent_size],
        );
        consumed += dent_size;
    }

    return .success(@bitCast(consumed));
}

/// Linux-compatible linux_dirent64 structure.
///
/// This structure has variable length described by `reclen` field.
const DirEnt64 = extern struct {
    const Self = @This();

    /// Inode number.
    inum: u64,
    /// Filesystem-specific value.
    spec: u64 = 0,
    /// Size of this structure.
    reclen: u16,
    /// File type (type-erased).
    type: u8 align(1),
    /// Filename starts here.
    __name_start: void = {},

    /// Size in bytes of the fixed-size part of this structure.
    const struct_size = @offsetOf(Self, "__name_start");
    /// Type of `reclen` field.
    const ReclenType = @FieldType(DirEnt64, "reclen");

    /// Calculate the entire structure size that has the specified name.
    ///
    /// - `name`: Name of the file. Must NOT be null-terminated.
    pub fn calcSize(name: []const u8) ReclenType {
        rtt.expect(0 != name[name.len - 1]);
        return @intCast(struct_size + name.len + 1); // +1 for null-termination.
    }

    /// Create a new DirEnt64 instance with the given name in the buffer.
    pub fn createCopy(inum: urd.fs.Inode.Number, ftype: FileType, name: []const u8, buf: []u8) void {
        const size = calcSize(name);
        rtt.expectEqual(size, buf.len);

        // Copy fixed-size part.
        const dirent = Self{
            .inum = inum,
            .reclen = size,
            .type = @intFromEnum(ftype),
        };
        var cur: [*]u8 = buf.ptr;
        @memcpy(cur[0..struct_size], std.mem.asBytes(&dirent)[0..struct_size]);
        cur += struct_size;

        // Copy name part.
        @memcpy(cur[0..name.len], name);
        cur[name.len] = 0; // null-terminate
    }

    comptime {
        urd.comptimeAssert(
            19 == struct_size,
            "Size of DirEnt64: Expected 19, but got {d}",
            .{struct_size},
        );
    }
};

// =============================================================
// fcntl
// =============================================================

/// syscall: fcntl
pub fn sysFcntl(fd: usize, op: FcntlOp, arg: u64) ReturnType {
    const cur = sched.getCurrent();

    switch (op) {
        .dupfd, .dupfd_cloexec => {
            const file = getFile(fd) catch return .err(.badf);
            const flags = FdFlags{ .cloexec = op == .dupfd_cloexec };
            const newfd = cur.fs.fdtbl.allocAt(
                @intCast(arg),
                file,
                flags,
            ) catch |err| return switch (err) {
                error.TableFull => .err(.mfile),
                else => .err(.badf),
            };
            return .success(@intCast(newfd));
        },

        .getfd => {
            _ = getFile(fd) catch return .err(.badf);
            return .success(@intCast(@as(u32, @bitCast(cur.fs.fdtbl.fd_flags[fd]))));
        },
        .setfd => {
            const flags: FdFlags = @bitCast(@as(u32, @truncate(arg)));
            if (flags._1 != 0) return .err(.inval);

            _ = getFile(fd) catch return .err(.badf);
            cur.fs.fdtbl.fd_flags[fd] = flags;
            return .success(0);
        },

        .getfl => {
            const file = getFile(fd) catch return .err(.badf);
            return .success(@intCast(file.status_flags));
        },
        .setfl => {
            const file = getFile(fd) catch return .err(.badf);
            file.status_flags = @truncate(arg);
            return .success(0);
        },

        _ => return .err(.nosys),
    }
}

/// File control operations.
const FcntlOp = enum(i32) {
    /// Duplicate the file descriptor fd using the lowest-numbered available fd greater than or equal to arg.
    dupfd = 0,
    /// Returns the file descriptor flags.
    getfd = 1,
    /// Set the file descriptor flags specified by arg.
    setfd = 2,
    /// Returns the file access mode and the file status flags.
    getfl = 3,
    /// Set the file status flags to the value specified by arg.
    setfl = 4,
    /// Same as dupfd, but set the close-on-exec flag on the duplicated descriptor.
    dupfd_cloexec = 1030,

    _,
};

// =============================================================
// ioctl
// =============================================================

/// syscall: ioctl
pub fn sysIoctl(fd: usize, request: u64, arg: usize) ReturnType {
    const file = getFile(fd) catch return .err(.badf);
    const result = file.ioctl(request, arg) catch |err| return switch (err) {
        error.Unsupported => .err(.notty),
        else => {
            log.warn("ioctl({d}) failed: {}", .{ request, err });
            return .err(.inval);
        },
    };
    return .success(@intCast(result));
}

// =============================================================
// chmod
// =============================================================

/// syscall: fchmodat
pub fn sysFchmodAt(dirfd: usize, pathname: [*:0]const u8, mode: u32) ReturnType {
    _ = mode; // TODO: should be implemented.

    const allocator = urd.mem.bin;
    const s = std.mem.span(pathname);

    _ = openFileAt(dirfd, s, allocator) catch |err|
        return mapOpenError(err);

    return .success(0);
}

// =============================================================
// CWD
// =============================================================

/// syscall: chdir
pub fn sysChdir(pathname: [*:0]const u8) ReturnType {
    const allocator = urd.mem.bin;
    const s = std.mem.span(pathname);

    const cur = sched.getCurrent();
    const path = urd.fs.resolve(s, allocator) catch |err| return switch (err) {
        error.InvalidArgument => .err(.inval),
        error.NotDirectory => .err(.notdir),
        error.NotFound => .err(.noent),
        else => .err(.again),
    };

    if (path.dentry.inode.ftype != .directory) {
        return .err(.notdir);
    }
    cur.fs.cwd = path;

    return .success(0);
}

/// syscall: getcwd
pub fn sysGetCwd(buf: usize, size: usize) ReturnType {
    const allocator = urd.mem.bin;
    const cur = sched.getCurrent();
    const path = urd.fs.getPath(cur.fs.cwd, allocator) catch
        return .err(.again);
    defer allocator.free(path);

    const out = @as([*]u8, @ptrFromInt(buf));
    if (size == 0) {
        return .err(.inval);
    }
    if (path.len + 1 > size) {
        return .err(.range);
    }

    @memcpy(out[0..path.len], path);
    out[path.len] = 0; // null-terminate

    return .success(@bitCast(path.len));
}

// =============================================================
// poll
// =============================================================

/// syscall: ppoll
///
/// - `fds`: Array of file descriptors to poll.
/// - `nfds`: Number of file descriptors in `fds`.
/// - `tmop`: Upper limit on the amount of time that this function will block.
/// - `sigmask`: TODO: Unused.
/// - `sigsetsize`: TODO: Unused.
pub fn sysPpoll(
    fds: [*]PollFd,
    nfds: usize,
    tmop: ?*const posix.Timespec,
    _: ?*const anyopaque,
    _: usize,
) ReturnType {
    if (nfds > Event.max_multiwait) {
        return .err(.inval);
    }

    const kfds = mem.bin.alloc(PollFd, nfds) catch return .err(.nomem);
    defer mem.bin.free(kfds);
    @memcpy(kfds, fds[0..nfds]);

    // Calculate deadline for blocking.
    const deadline_ns = if (tmop) |t| blk: {
        const dur_ns: u64 = @intCast(t.sec * std.time.ns_per_s + @as(i64, @intCast(t.nsec)));
        break :blk urd.time.getCurrentTimestamp() + dur_ns;
    } else null;

    const done: usize = while (true) {
        var n_ready: usize = 0;
        var wait_events: [Event.max_multiwait - 1]*Event = undefined;
        var n_events: usize = 0;

        // Check if any of the file descriptors are ready.
        for (kfds) |*pfd| {
            pfd.revents = .empty;

            // Ignore negative descriptors.
            if (pfd.fd < 0) continue;

            // Poll the file readiness.
            const file = getFile(@intCast(pfd.fd)) catch {
                pfd.revents.nval = true;
                n_ready += 1;
                continue;
            };
            const result = file.poll() catch {
                pfd.revents.err = true;
                n_ready += 1;
                continue;
            };
            const ready = std.mem.zeroInit(PollEvents, .{
                .in = result.events.in,
                .pri = result.events.urgent,
                .out = result.events.out,
            });
            pfd.revents = pfd.events.eand(ready);

            if (pfd.revents != PollEvents.empty) {
                n_ready += 1;
            } else if (result.wait) |ev| {
                wait_events[n_events] = ev;
                n_events += 1;
            }
        }

        // If at least one event is ready, return.
        if (n_ready > 0) {
            break n_ready;
        }

        // If it already reached the deadline, return.
        if (deadline_ns) |dl| {
            if (urd.time.getCurrentTimestamp() >= dl) break @as(usize, 0);
        }

        if (n_events > 0 or deadline_ns != null)
            _ = Event.waitAny(
                wait_events[0..n_events],
                deadline_ns,
            )
        else
            sched.reschedule();
    };

    @memcpy(fds[0..nfds], kfds);
    return .success(@intCast(done));
}

/// POSIX-compliant pollfd structure.
const PollFd = extern struct {
    /// File descriptor.
    fd: i32,
    /// Requested events.
    events: PollEvents,
    /// Returned events.
    revents: PollEvents,
};

/// POSIX-compliant event type that can be polled for.
const PollEvents = packed struct(u16) {
    /// There is data to read.
    in: bool,
    /// There is urgent data to read.
    pri: bool,
    /// Writing now will not block.
    out: bool,

    // =============================================================
    // Always implicitly polled for.
    // Users should not include these in `events`, but `revents` may contain these values.

    /// Error condition.
    err: bool,
    /// Hung up.
    hup: bool,
    /// Invalid polling request.
    nval: bool,

    /// Reserved.
    _6: u10 = 0,

    const empty = std.mem.zeroes(PollEvents);

    /// Bitwise AND of two PollEvents.
    fn eand(self: PollEvents, other: PollEvents) PollEvents {
        return @bitCast(@as(u16, @bitCast(self)) & @as(u16, @bitCast(other)));
    }
};

// =============================================================
// Internal
// =============================================================

/// Convert open-related error to syscall return type.
fn mapOpenError(err: anyerror) ReturnType {
    return switch (err) {
        urd.fs.Error.InvalidArgument => .err(.inval),
        urd.fs.Error.NotDirectory => .err(.notdir),
        urd.fs.Error.NotFound => .err(.noent),
        error.BadFileDescriptor => .err(.badf),
        else => .err(.again),
    };
}

/// Get a file from the given file descriptor.
fn getFile(fd: usize) error{BadFileDescriptor}!*urd.fs.File {
    const cur = sched.getCurrent();
    const file = cur.fs.fdtbl.get(fd) catch return error.BadFileDescriptor;
    return file orelse error.BadFileDescriptor;
}

/// Open a file at the specified path relative to the given directory file descriptor.
fn openFileAt(dirfd: usize, pathname: []const u8, allocator: Allocator) (error{BadFileDescriptor} || urd.fs.Error)!*urd.fs.File {
    // Check if pathname is relative or absolute.
    if (std.fs.path.isAbsolute(pathname)) {
        // Absolute path. Ignore directory.
        return urd.fs.open(pathname, allocator);
    } else if (dirfd == cwd_fd) {
        // Relative to CWD.
        const cur = sched.getCurrent();
        return urd.fs.openAt(cur.fs.cwd, pathname, allocator);
    } else {
        // Relative to dirfd.
        const cur = sched.getCurrent();
        const dir = cur.fs.fdtbl.get(dirfd) catch {
            return error.BadFileDescriptor;
        } orelse {
            return error.BadFileDescriptor;
        };

        return urd.fs.openAt(dir.path, pathname, allocator);
    }
}

/// Create a file at the specified path relative to the given directory file descriptor.
fn createFileAt(dirfd: usize, pathname: []const u8, allocator: Allocator) (error{BadFileDescriptor} || urd.fs.Error)!*urd.fs.File {
    // Check if pathname is relative or absolute.
    if (std.fs.path.isAbsolute(pathname)) {
        // Absolute path. Ignore directory.
        return urd.fs.create(pathname, allocator);
    } else if (dirfd == cwd_fd) {
        // Relative to CWD.
        const cur = sched.getCurrent();
        return urd.fs.createAt(cur.fs.cwd, pathname, allocator);
    } else {
        // Relative to dirfd.
        const cur = sched.getCurrent();
        const dir = cur.fs.fdtbl.get(dirfd) catch {
            return error.BadFileDescriptor;
        } orelse {
            return error.BadFileDescriptor;
        };

        return urd.fs.createAt(dir.path, pathname, allocator);
    }
}

/// Remove a file at the specified path relative to the given directory file descriptor.
fn unlinkFileAt(dirfd: usize, pathname: []const u8, allocator: Allocator) (error{BadFileDescriptor} || urd.fs.Error)!void {
    // Check if pathname is relative or absolute.
    if (std.fs.path.isAbsolute(pathname)) {
        // Absolute path. Ignore directory.
        return urd.fs.unlink(pathname, allocator);
    } else if (dirfd == cwd_fd) {
        // Relative to CWD.
        const cur = sched.getCurrent();
        return urd.fs.unlinkAt(cur.fs.cwd, pathname, allocator);
    } else {
        // Relative to dirfd.
        const cur = sched.getCurrent();
        const dir = cur.fs.fdtbl.get(dirfd) catch {
            return error.BadFileDescriptor;
        } orelse {
            return error.BadFileDescriptor;
        };

        return urd.fs.unlinkAt(dir.path, pathname, allocator);
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.pxfs);
const Allocator = std.mem.Allocator;
const common = @import("common");
const bits = common.bits;
const rtt = common.rtt;
const urd = @import("urthr");
const mem = urd.mem;
const posix = urd.posix;
const sched = urd.sched;
const Event = urd.sync.Event;
const FdFlags = urd.fs.FdTable.FdFlags;
const ReturnType = urd.syscall.ReturnType;
