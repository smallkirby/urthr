/// syscall: uname
pub fn sysUname(buf: *UtsName) ReturnType {
    var uts = std.mem.zeroes(UtsName);
    std.mem.copyForwards(u8, &uts.sysname, "Urthr");

    if (hostname) |h| {
        std.mem.copyForwards(u8, &uts.nodename, h);
    } else {
        std.mem.copyForwards(u8, &uts.nodename, "urthr");
    }

    std.mem.copyForwards(u8, &uts.release, urd.version);
    std.mem.copyForwards(u8, &uts.version, urd.version);
    std.mem.copyForwards(u8, &uts.machine, @tagName(builtin.cpu.arch));

    urd.uaccess.putUser(
        UtsName,
        buf,
        uts,
    ) catch return .err(.fault);

    return .success(0);
}

/// syscall: sethostname
pub fn sysSetHostname(name: [*]const u8, len: usize) ReturnType {
    if (len > max_hostname_len) {
        return .err(.inval);
    }

    var namebuf: [max_hostname_len]u8 = undefined;
    urd.uaccess.copyFromUser(
        namebuf[0..len],
        name,
    ) catch return .err(.fault);

    if (hostname) |h| {
        urd.mem.bin.free(h);
        hostname = null;
    }
    hostname = urd.mem.bin.dupe(u8, namebuf[0..len]) catch {
        return .err(.nomem);
    };

    return .success(0);
}

/// Current host name.
var hostname: ?[]const u8 = null;

/// Maximum host name length.
const max_hostname_len = 64;

const UtsName = struct {
    /// Operating system name.
    sysname: [65]u8,
    /// Name within communications network to which the node is attached if any.
    nodename: [65]u8,
    /// Operating system release.
    release: [65]u8,
    /// Operating system version.
    version: [65]u8,
    /// Hardware type ID.
    machine: [65]u8,
};

/// syscall: getrandom
pub fn sysGetRandom(buf: ?[*]u8, buflen: usize, flags: GetRandomFlags) ReturnType {
    if (flags._2 != 0) return .err(.inval);
    if (buflen == 0) return .success(0);
    if (buf == null) return .err(.fault);

    const uaddr = @intFromPtr(buf.?);
    if (!urd.uaccess.accessOk(uaddr, buflen)) return .err(.fault);

    var chunk: [256]u8 = undefined;
    var done: usize = 0;
    while (done < buflen) {
        const want = @min(chunk.len, buflen - done);
        urd.rng.getRandom(chunk[0..want]);

        urd.uaccess.copyToUser(
            uaddr + done,
            chunk[0..want],
        ) catch return if (done != 0)
            .success(@bitCast(done))
        else
            .err(.fault);

        done += want;
    }

    return .success(@bitCast(buflen));
}

/// Flags for `getrandom` syscall.
const GetRandomFlags = packed struct(u32) {
    /// Use the random source instead of the urandom source.
    random: bool = false,
    /// Do not block.
    nonblock: bool = false,
    /// Reserved.
    _2: u30 = 0,
};

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const common = @import("common");
const urd = @import("urthr");
const sched = urd.sched;
const task = urd.task;
const ReturnType = urd.syscall.ReturnType;
