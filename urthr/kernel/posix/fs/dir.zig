// =============================================================
// mkdir

/// syscall: mkdirat
pub fn sysMkdirAt(dirfd: i32, pathname: [*:0]const u8, mode: Mode) ReturnType {
    var upath: helper.UserPath = .{};
    const path = upath.copyFrom(pathname) orelse return .err(.fault);

    mkdirFileAt(
        dirfd,
        path,
        effectiveMode(mode),
        urd.mem.bin,
    ) catch |err| return maperror(err);

    return .success(0);
}

/// syscall: mkdir
pub fn sysMkdir(pathname: [*:0]const u8, mode: Mode) ReturnType {
    return sysMkdirAt(helper.cwd_fd, pathname, mode);
}

// =============================================================
// cwd

/// syscall: chdir
pub fn sysChdir(pathname: [*:0]const u8) ReturnType {
    var upath: helper.UserPath = .{};
    const path = upath.copyFrom(pathname) orelse return .err(.fault);

    const resolved = fs.resolve(
        path,
        urd.mem.bin,
        true,
    ) catch |err| return maperror(err);

    if (resolved.dentry.getInode().ftype != .directory) {
        resolved.put();
        return .err(.notdir);
    }
    sched.getCurrent().fs.info.setCwd(resolved);

    return .success(0);
}

/// syscall: fchdir
pub fn sysFchdir(fd: i32) ReturnType {
    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();

    if (file.getType() != .directory) {
        return .err(.notdir);
    }
    sched.getCurrent().fs.info.setCwd(file.path.get());

    return .success(0);
}

/// syscall: getcwd
pub fn sysGetCwd(buf: usize, size: usize) ReturnType {
    if (size == 0) {
        return .err(.inval);
    }

    const cwd = sched.getCurrent().fs.info.getCwd();
    defer cwd.put();
    const path = fs.getPath(cwd, urd.mem.bin) catch {
        return .err(.again);
    };
    defer urd.mem.bin.free(path);

    if (path.len + 1 > size) {
        return .err(.range);
    }

    uaccess.copyToUser(buf, path) catch return .err(.fault);
    uaccess.copyToUser(buf + path.len, "\x00") catch return .err(.fault);

    return .success(@bitCast(path.len + 1)); // +1 for NULL-terminator
}

// =============================================================
// getdents

/// syscall: getdents64
pub fn sysGetDents64(fd: i32, ents: [*]u8, count: usize) ReturnType {
    const allocator = urd.mem.bin;
    const uaddr = @intFromPtr(ents);

    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();
    if (file.getType() != .directory) {
        return .err(.notdir);
    }
    if (!uaccess.accessOk(uaddr, count)) {
        return .err(.fault);
    }

    var dbuf: [DirEnt64.struct_size + 256]u8 = undefined;
    var consumed: usize = 0;
    var iter = file.iterator() catch |e| return maperror(e);
    while (true) {
        const resume_offset = iter.offset;
        const ent = (iter.next(allocator) catch return .err(.again)) orelse break;
        defer ent.deinit(allocator);

        const dent_size = DirEnt64.calcSize(ent.name);
        if (count - consumed < dent_size or dent_size > dbuf.len) {
            file.offset = resume_offset;
            return progressOr(consumed, .err(.inval));
        }

        DirEnt64.createCopy(
            ent.inum,
            .from(ent.type),
            ent.name,
            dbuf[0..dent_size],
        );
        uaccess.copyToUser(
            uaddr + consumed,
            dbuf[0..dent_size],
        ) catch {
            file.offset = resume_offset;
            return progressOr(consumed, .err(.fault));
        };
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
    const ReclenType = @FieldType(Self, "reclen");

    /// Calculate the entire structure size that has the specified name.
    ///
    /// - `name`: Name of the file. Must NOT be null-terminated.
    fn calcSize(name: []const u8) ReclenType {
        rtt.expect(0 != name[name.len - 1]);
        return @intCast(struct_size + name.len + 1); // +1 for null-termination.
    }

    /// Create a new DirEnt64 instance with the given name in the buffer.
    fn createCopy(inum: fs.Inode.Number, ftype: FileType, name: []const u8, buf: []u8) void {
        const size = calcSize(name);
        rtt.expectEqual(size, buf.len);

        // Copy fixed-size part.
        const dirent = Self{
            .inum = inum,
            .reclen = size,
            .type = @backingInt(ftype),
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
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const fs = urd.fs;
const sched = urd.sched;
const uaccess = urd.uaccess;
const ReturnType = urd.syscall.ReturnType;

const abi = @import("abi.zig");
const helper = @import("helper.zig");
const Mode = abi.Mode;
const FileType = abi.FileType;
const maperror = helper.maperror;
const getFile = helper.getFile;
const effectiveMode = helper.effectiveMode;
const mkdirFileAt = helper.mkdirFileAt;
const progressOr = helper.progressOr;
