/// syscall: fstat
pub fn sysFstat(fd: i32, statbuf: *align(1) Stat) ReturnType {
    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();

    uaccess.putUser(
        Stat,
        statbuf,
        statFromFile(file),
    ) catch return .err(.fault);

    return .success(0);
}

/// Flags accepted by `newfstatat` and `statx`.
const stat_at_flags = AtFlags{
    .symlink_nofollow = true,
    .empty_path = true,
    .no_automount = true,
};

/// Get the number of 512B blocks needed to hold the file.
fn blocksOf(file: *fs.File) u64 {
    return (file.size() + 511) / 512;
}

/// Build a stat structure from an open file.
fn statFromFile(file: *fs.File) Stat {
    const times = file.getTimes();
    const atime = times.atime.to();
    const mtime = times.mtime.to();
    const ctime = times.ctime.to();

    return .{
        .st_dev = 0,
        .st_ino = file.path.dentry.getInode().number,
        .st_mode = @bitCast(Mode.from(file)),
        .st_nlink = 1,
        .st_uid = file.getUid(),
        .st_gid = file.getGid(),
        .st_rdev = 0,
        .st_size = @intCast(file.size()),
        .st_blksize = 512,
        .st_blocks = @intCast(blocksOf(file)),
        .st_atime = atime.sec,
        .st_atime_nsec = atime.nsec,
        .st_mtime = mtime.sec,
        .st_mtime_nsec = mtime.nsec,
        .st_ctime = ctime.sec,
        .st_ctime_nsec = ctime.nsec,
    };
}

/// Convert FS timestamp to a `statx` timestamp.
fn statxTimestamp(ts: fs.Timestamp) Statx.Timestamp {
    const parts = ts.to();
    return .{ .sec = parts.sec, .nsec = @intCast(parts.nsec) };
}

/// syscall: newfstatat
pub fn sysNewFstatAt(
    dirfd: i32,
    pathname: [*:0]const u8,
    statbuf: *align(1) Stat,
    flags: AtFlags,
) ReturnType {
    if (!flags.isFit(stat_at_flags)) {
        return .err(.inval);
    }

    const resolved = ResolveFile.atUser(
        dirfd,
        pathname,
        flags,
        urd.mem.bin,
    ) catch |err| return maperror(err);
    defer resolved.deinit();

    uaccess.putUser(
        Stat,
        statbuf,
        statFromFile(resolved.file),
    ) catch return .err(.fault);

    return .success(0);
}

/// syscall: stat
pub fn sysStat(pathname: [*:0]const u8, statbuf: *align(1) Stat) ReturnType {
    return sysNewFstatAt(helper.cwd_fd, pathname, statbuf, .{});
}

/// syscall: lstat
pub fn sysLstat(pathname: [*:0]const u8, statbuf: *align(1) Stat) ReturnType {
    return sysNewFstatAt(helper.cwd_fd, pathname, statbuf, .{
        .symlink_nofollow = true,
    });
}

/// syscall: statx
///
/// TODO: respect the `mask` argument.
pub fn sysStatx(
    dirfd: i32,
    pathname: [*:0]const u8,
    flags: AtFlags,
    _: u32,
    statxbuf: *align(1) Statx,
) ReturnType {
    if (!flags.isFit(stat_at_flags)) {
        return .err(.inval);
    }

    const resolved = ResolveFile.atUser(
        dirfd,
        pathname,
        flags,
        urd.mem.bin,
    ) catch |err| return maperror(err);
    defer resolved.deinit();

    uaccess.putUser(
        Statx,
        statxbuf,
        statxFromFile(resolved.file),
    ) catch return .err(.fault);

    return .success(0);
}

/// Build a statx structure from an open file.
fn statxFromFile(file: *fs.File) Statx {
    const times = file.getTimes();
    return .{
        .mask = 0x7FF,
        .blksize = 512,
        .attributes = 0, // TODO
        .nlink = 1, // TODO
        .uid = file.getUid(),
        .gid = file.getGid(),
        .mode = @truncate(@as(u32, @bitCast(Mode.from(file)))),
        .ino = file.path.dentry.getInode().number,
        .size = @intCast(file.size()),
        .blocks = blocksOf(file),
        .attributes_mask = 0, // TODO
        .atime = statxTimestamp(times.atime),
        .btime = statxTimestamp(times.ctime),
        .ctime = statxTimestamp(times.ctime),
        .mtime = statxTimestamp(times.mtime),
        .rdev_major = 0, // TODO
        .rdev_minor = 0, // TODO
        .dev_major = 0, // TODO
        .dev_minor = 0, // TODO
    };
}

const Stat = switch (builtin.cpu.arch) {
    .aarch64 => extern struct {
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
        /// Padding.
        __pad: u64 = 0,
        /// Total size in bytes.
        st_size: i64,
        /// Block size for filesystem I/O.
        st_blksize: i32,
        /// Padding.
        __pad2: i32 = 0,
        /// Number of 512B blocks allocated.
        st_blocks: i64,
        /// Time of last access.
        st_atime: i64 = 0,
        /// Nanoseconds of last access.
        st_atime_nsec: i64 = 0,
        /// Time of last modification.
        st_mtime: i64 = 0,
        /// Nanoseconds of last modification.
        st_mtime_nsec: i64 = 0,
        /// Time of last status change.
        st_ctime: i64 = 0,
        /// Nanoseconds of last status change.
        st_ctime_nsec: i64 = 0,
        /// Padding.
        __unused: [2]u32 = @splat(0),

        comptime {
            if (@sizeOf(Stat) != 128) {
                @compileError("Invalid Stat struct size.");
            }
        }
    },
    .x86_64 => extern struct {
        /// Device ID.
        st_dev: u64,
        /// Inode number.
        st_ino: u64,
        /// Number of hard links.
        st_nlink: u64,
        /// File mode.
        st_mode: u32,
        /// User ID of owner.
        st_uid: u32,
        /// Group ID of owner.
        st_gid: u32,
        /// Reserved.
        __pad0: u32 = 0,
        /// Device ID (if special file).
        st_rdev: u64,
        /// Total size, in bytes.
        st_size: i64,
        /// Block size for filesystem I/O.
        st_blksize: i64,
        /// Number of 512B blocks allocated.
        st_blocks: i64,
        /// Time of last access.
        st_atime: i64 = 0,
        /// Nanoseconds of last access.
        st_atime_nsec: i64 = 0,
        /// Time of last modification.
        st_mtime: i64 = 0,
        /// Nanoseconds of last modification.
        st_mtime_nsec: i64 = 0,
        /// Time of last status change.
        st_ctime: i64 = 0,
        /// Nanoseconds of last status change.
        st_ctime_nsec: i64 = 0,
        /// Padding.
        __unused: [3]i64 = @splat(0),

        comptime {
            if (@sizeOf(Stat) != 144) {
                @compileError("Invalid Stat struct size.");
            }
        }
    },
    else => extern struct {},
};

const Statx = extern struct {
    /// Mask of bits indicating filled fields.
    mask: u32,
    /// Block size for filesystem I/O.
    blksize: u32,
    /// Extra file attribute indicators.
    attributes: u64,
    /// Number of hard links.
    nlink: u32,
    /// User ID of owner.
    uid: u32,
    /// Group ID of owner.
    gid: u32,
    /// File type and mode.
    mode: u16,
    /// Reserved.
    __spare0: u16 = 0,
    /// Inode number.
    ino: u64,
    /// Total size in bytes.
    size: u64,
    /// Number of 512B blocks allocated.
    blocks: u64,
    /// Mask to show what's supported in `attributes`.
    attributes_mask: u64,

    /// Last access time.
    atime: Timestamp,
    /// Creation time.
    btime: Timestamp,
    /// Last status change time.
    ctime: Timestamp,
    /// Last modification time.
    mtime: Timestamp,

    /// Major ID.
    rdev_major: u32,
    /// Minor ID.
    rdev_minor: u32,
    /// Major ID of the device containing the filesystem where this file resides.
    dev_major: u32,
    /// Minor ID of the device containing the filesystem where this file resides.
    dev_minor: u32,
    /// Mount ID.
    mnt_id: u64 = 0,

    /// Memory buffer alignment for direct I/O.
    dio_mem_align: u32 = 0,
    /// File offset alignment for direct I/O.
    dio_offset_align: u32 = 0,
    /// Subvolume identifier.
    subvol: u64 = 0,
    /// Min atomic write unit in bytes.
    atomic_write_unit_min: u32 = 0,
    /// Max atomic write unit in bytes.
    atomic_write_unit_max: u32 = 0,
    /// Max atomic write segment count.
    atomic_write_segments_max: u32 = 0,
    /// File offset alignment for direct I/O reads.
    dio_read_offset_align: u32 = 0,
    /// Optimised max atomic write unit in bytes.
    atomic_write_unit_max_opt: u32 = 0,

    /// Reserved.
    __spare2: [1]u32 = @splat(0),
    /// Reserved.
    __spare3: [8]u64 = @splat(0),

    comptime {
        if (@sizeOf(Statx) != 256) {
            @compileError("Invalid Statx struct size.");
        }
    }

    const Timestamp = extern struct {
        /// Number of seconds before or after `1970-01-01T00:00:00Z`.
        sec: i64,
        /// Number of nanoseconds after `sec`.
        nsec: u32,
        /// Reserved.
        __pad1: u32 = 0,
    };
};

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const urd = @import("urthr");
const fs = urd.fs;
const uaccess = urd.uaccess;
const ReturnType = urd.syscall.ReturnType;

const abi = @import("abi.zig");
const helper = @import("helper.zig");
const AtFlags = abi.AtFlags;
const Mode = abi.Mode;
const ResolveFile = helper.ResolveFile;
const maperror = helper.maperror;
const getFile = helper.getFile;
