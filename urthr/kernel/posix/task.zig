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

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const sched = urd.sched;
const task = urd.task;
const ReturnType = urd.syscall.ReturnType;
