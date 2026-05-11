/// System call: exit_group
pub fn sysExitGroup(code: i32) ReturnType {
    task.exit(code);
}

/// System call: gettid
pub fn sysGetTid() ReturnType {
    const current = sched.getCurrent();
    return .success(@bitCast(@as(u64, current.id)));
}

/// System call: prlimit64
pub fn prlimit64(pid: i32, resource: i32, new_rlim: usize, old_rlim: usize) ReturnType {
    if (pid != 0) {
        return .err(.perm);
    }

    // TODO: implement
    _ = resource;
    _ = new_rlim;
    _ = old_rlim;

    return .success(0);
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
