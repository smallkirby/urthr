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
pub fn sysOpenAt(dirfd: usize, pathname: [*:0]const u8, flags: i32, mode: u32) ReturnType {
    _ = mode;
    _ = flags;

    const allocator = urd.mem.getGeneralAllocator();
    const s = std.mem.span(pathname);

    const file = openFileAt(dirfd, s, allocator) catch |err| return switch (err) {
        urd.fs.Error.InvalidArgument => .err(.inval),
        urd.fs.Error.NotDirectory => .err(.notdir),
        urd.fs.Error.NotFound => .err(.noent),
        error.BadFileDescriptor => .err(.badf),
        else => .err(.again),
    };
    const fd = sched.getCurrent().fs.fdtbl.alloc(file) catch {
        return .err(.mfile);
    };

    return .success(@bitCast(fd));
}

/// syscall: close
pub fn sysClose(fd: usize) ReturnType {
    sched.getCurrent().fs.fdtbl.close(fd) catch {
        return .err(.badf);
    };

    return .success(0);
}

// =============================================================
// Write
// =============================================================

/// syscall: write
pub fn sysWrite(fd: usize, buf: usize, count: usize) ReturnType {
    const cur = sched.getCurrent();
    const file = cur.fs.fdtbl.get(fd) catch {
        return .err(.badf);
    } orelse {
        return .err(.badf);
    };

    const out = @as([*]const u8, @ptrFromInt(buf));

    const n = file.write(out[0..count]) catch |err| return switch (err) {
        else => .err(.again),
    };
    return .success(@bitCast(n));
}

/// syscall: writev
pub fn sysWritev(fd: usize, iov: usize, iovcnt: usize) ReturnType {
    const cur = sched.getCurrent();
    const iovs = @as([*]const Iovec, @ptrFromInt(iov))[0..iovcnt];

    const file = cur.fs.fdtbl.get(fd) catch {
        return .err(.badf);
    } orelse {
        return .err(.badf);
    };

    var total: usize = 0;
    for (iovs) |v| {
        total += file.write(v.slice()) catch |err| return switch (err) {
            else => .err(.again),
        };
    }

    return .success(@bitCast(total));
}

/// syscall: pwritev
pub fn sysPwritev(fd: usize, iov: [*]const Iovec, iovcnt: usize, offset_l: u32, offset_h: u32) ReturnType {
    const cur = sched.getCurrent();
    const offset = bits.concat(u64, offset_h, offset_l);
    const iovs = iov[0..iovcnt];

    const file = cur.fs.fdtbl.get(fd) catch {
        return .err(.badf);
    } orelse {
        return .err(.badf);
    };

    if (offset != 0) {
        return .err(.nosys); // TODO: Not implemented.
    }

    var total: usize = 0;
    for (iovs) |v| {
        const n = file.write(v.slice()) catch |err| return switch (err) {
            else => .err(.again),
        };
        total += n;
    }

    return .success(@bitCast(total));
}

// =============================================================
// Read
// =============================================================

/// syscall: preadv
pub fn sysPreadv(fd: usize, iov: [*]const Iovec, iovcnt: usize, offset_l: u32, offset_h: u32) ReturnType {
    const cur = sched.getCurrent();
    const offset = bits.concat(u64, offset_h, offset_l);
    const iovs = iov[0..iovcnt];

    const file = cur.fs.fdtbl.get(fd) catch {
        return .err(.badf);
    } orelse {
        return .err(.badf);
    };

    if (offset != 0) {
        return .err(.nosys); // TODO: Not implemented.
    }

    var total: usize = 0;
    for (iovs) |v| {
        const r = file.read(v.slice()) catch |err| return switch (err) {
            else => .err(.again),
        };
        total += r.len;
    }

    return .success(@bitCast(total));
}

// =============================================================
// Stat
// =============================================================

/// syscall: newfstatat
pub fn sysNewFstatAt(dirfd: usize, pathname: [*:0]const u8, statbuf: *Stat, flags: i32) ReturnType {
    _ = flags; // TODO: should be implemented.

    const allocator = urd.mem.getGeneralAllocator();
    const s = std.mem.span(pathname);

    // Check if pathname is relative or absolute.
    const E = urd.fs.Error;
    const file = openFileAt(dirfd, s, allocator) catch |err| return switch (err) {
        E.InvalidArgument => .err(.inval),
        E.NotDirectory => .err(.notdir),
        E.NotFound => .err(.noent),
        error.BadFileDescriptor => .err(.badf),
        else => .err(.again),
    };

    const stat = Stat{
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
    statbuf.* = stat;

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

    pub fn from(f: *const urd.fs.File) Mode {
        return Mode{
            .type = switch (f.getType()) {
                .regular => .regular,
                .directory => .dir,
            },
        };
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
};

// =============================================================
// getdents
// =============================================================

/// syscall: getdents64
pub fn sysGetDents64(fd: usize, ents: [*]u8, count: usize) ReturnType {
    const allocator = urd.mem.getGeneralAllocator();
    const cur = sched.getCurrent();
    const file = cur.fs.fdtbl.get(fd) catch {
        return .err(.badf);
    } orelse {
        return .err(.badf);
    };
    if (file.getType() != .directory) {
        return .err(.notdir);
    }

    var consumed: usize = 0;
    var iter = file.iterator() catch |err| return switch (err) {
        else => .err(.again),
    };
    while (true) {
        const ent = (iter.next(allocator) catch |err| return switch (err) {
            else => .err(.again),
        }) orelse break;
        defer ent.deinit(allocator);

        const dent_size = DirEnt64.calcSize(ent.name);
        if (count - consumed < dent_size) {
            break;
        }

        const ptr = ents + consumed;
        const ftype: FileType = switch (ent.type) {
            .regular => .regular,
            .directory => .dir,
        };
        DirEnt64.createCopy(
            ent.inum,
            ftype,
            ent.name,
            ptr[0..dent_size],
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
// ioctl
// =============================================================

/// syscall: ioctl
pub fn sysIoctl(fd: usize, request: IoctlRequest, arg: usize) ReturnType {
    _ = fd;
    _ = arg;

    switch (request) {
        // TIOCGWINSZ
        .tiocgwinsz => {
            return .err(.notty);
        },

        // Unrecognized requests.
        _ => return .err(.inval),
    }
}

const IoctlRequest = enum(u64) {
    /// Get window size.
    tiocgwinsz = 0x5413,

    _,
};

// =============================================================
// chmod
// =============================================================

/// syscall: fchmodat
pub fn sysFchmodAt(dirfd: usize, pathname: [*:0]const u8, mode: u32) ReturnType {
    _ = mode; // TODO: should be implemented.

    const allocator = urd.mem.getGeneralAllocator();
    const s = std.mem.span(pathname);

    // We try to open the file, but we don't operate on the file itself for now.
    _ = openFileAt(dirfd, s, allocator) catch |err| return switch (err) {
        urd.fs.Error.InvalidArgument => .err(.inval),
        urd.fs.Error.NotDirectory => .err(.notdir),
        urd.fs.Error.NotFound => .err(.noent),
        error.BadFileDescriptor => .err(.badf),
        else => .err(.again),
    };

    return .success(0);
}

// =============================================================
// CWD
// =============================================================

/// syscall: chdir
pub fn sysChdir(pathname: [*:0]const u8) ReturnType {
    const allocator = urd.mem.getGeneralAllocator();
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

// =============================================================
// Internal
// =============================================================/

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

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const bits = common.bits;
const rtt = common.rtt;
const urd = @import("urthr");
const sched = urd.sched;
const ReturnType = urd.syscall.ReturnType;
