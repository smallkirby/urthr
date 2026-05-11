/// System call: brk
pub fn sysBrk(addr: usize) ReturnType {
    const current = sched.getCurrent();

    // Query current program break if addr is 0.
    if (addr == 0) {
        return .success(@bitCast(current.vmm.brk));
    }

    // Extend the program break to the given address.
    const aligned_addr = std.mem.alignForward(usize, addr, urd.mem.page_size);
    const new = current.vmm.extendProgramBreak(aligned_addr) catch |e| switch (e) {
        error.OutOfMemory => return ReturnType.err(.nomem),
        else => return ReturnType.err(.again),
    };

    return .success(@bitCast(new));
}

/// System call: mprotect
pub fn sysMprotect(addr: usize, len: usize, prot: Mprot) ReturnType {
    if (addr % urd.mem.page_size != 0) return ReturnType.err(.inval);

    const current = sched.getCurrent();
    const aligned_len = std.mem.alignForward(usize, len, urd.mem.page_size);

    if (aligned_len == 0) {
        return .success(0);
    }

    current.vmm.remap(addr, aligned_len, prot.permission()) catch |e| switch (e) {
        error.OutOfMemory => return ReturnType.err(.nomem),
        else => return ReturnType.err(.inval),
    };

    return .success(0);
}

/// Memory protection flags.
const Mprot = packed struct(u32) {
    /// Readable.
    read: bool,
    /// Writable.
    write: bool,
    /// Executable.
    exec: bool,
    _3: u21 = 0,
    /// Whether the mapping grows downwards.
    growsdown: bool,
    /// Whether the mapping grows upwards.
    growsup: bool,
    _26: u6 = 0,

    fn permission(self: Mprot) Permission {
        return .{
            .ur = self.read,
            .uw = self.write,
            .ux = self.exec,
            .kr = true,
            .kw = self.write,
            .kx = false,
        };
    }
};

/// System call: mmap
pub fn sysMmap(addr: usize, len: usize, prot: Mprot, flags: MmapFlags, fd: i64, offset: usize) ReturnType {
    const cur = sched.getCurrent();

    if (addr != 0) {
        return .err(.inval); // Not supported
    }
    if (fd != -1) {
        return .err(.nosys); // Not supported
    }
    if (!flags.private or !flags.anonymous) {
        return .err(.inval); // Not supported
    }
    _ = offset;

    if (len == 0) {
        return .err(.inval);
    }
    const aligned_len = std.mem.alignForward(usize, len, urd.mem.page_size);

    // Currently, supports only anonymous private mapping without address hint.
    const mapped = cur.vmm.mapAnon(aligned_len, prot.permission()) catch |e| switch (e) {
        error.OutOfMemory => return .err(.nomem),
        else => return .err(.inval),
    };

    return .success(@bitCast(mapped));
}

/// System call: munmap
pub fn sysMunmap(addr: usize, len: usize) ReturnType {
    const cur = sched.getCurrent();

    if (addr % urd.mem.page_size != 0) {
        return .err(.inval);
    }
    if (len % urd.mem.page_size != 0) {
        return .err(.inval);
    }

    cur.vmm.unmap(addr, len) catch |e| switch (e) {
        error.OutOfMemory => return .err(.nomem),
        else => return .err(.inval),
    };

    return .success(0);
}

/// Memory mapping flags.
const MmapFlags = packed struct(u32) {
    /// Share changes.
    shared: bool,
    /// Changes are private.
    private: bool,
    /// Share changes and validate extension flags.
    shared_validate: bool,
    /// Not used.
    _3: u1 = 0,

    /// Interpret addr exactly.
    fixed: bool,
    /// Don't use a file.
    anonymous: bool,
    /// Not used.
    _6: u26 = 0,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const Permission = common.mem.Permission;
const urd = @import("urthr");
const sched = urd.sched;
const task = urd.task;
const ReturnType = urd.syscall.ReturnType;
