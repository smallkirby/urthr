/// System call: exit_group
pub fn sysExitGroup(code: i32) ReturnType {
    task.exit(code);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const task = urd.task;
const ReturnType = urd.syscall.ReturnType;
