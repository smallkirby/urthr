/// System call: exit_group
pub fn sysExitGroup(code: i32) ReturnType {
    task.exit(code);
}

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

/// System call: gettid
pub fn sysGetTid() ReturnType {
    const current = sched.getCurrent();
    return .success(@bitCast(@as(u64, current.id)));
}

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
