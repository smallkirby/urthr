/// syscall: exit
pub fn sysExit(code: i32) ReturnType {
    task.exit(.{ .code = code });
}

/// syscall: exit_group
pub fn sysExitGroup(code: i32) ReturnType {
    task.exitGroup(.{ .code = code });
}

/// syscall: wait4
pub fn sysWait4(pid: i32, wstatus: *allowzero i32, options: WaitOptions, _: usize) ReturnType {
    const result = task.waitChild(
        pid,
        options.nohang,
    ) catch |err| switch (err) {
        error.NoChild => return .err(.child),
    } orelse return .success(0);

    if (@intFromPtr(wstatus) != 0) {
        wstatus.* = switch (result.exit_status) {
            .code => |c| (c & 0xFF) << 8,
            .signal => |s| @intCast(@intFromEnum(s) & 0x7F),
        };
    }

    return .success(@intCast(result.pid));
}

const WaitOptions = packed struct(u32) {
    /// Dont't block waiting.
    nohang: bool,
    /// Report status of children.
    untraced: bool,
    /// Reserved.
    _2: u30 = 0,
};

/// syscall: clone
pub fn sysClone(flags: CloneFlags, stack: usize, parent_tidp: usize, child_tidp: usize, tls: usize) ReturnType {
    _ = parent_tidp;
    _ = child_tidp;
    _ = tls;

    if (flags.fs) urd.unimplemented("clone: share FS");
    if (flags.files) urd.unimplemented("clone: share open files");
    if (flags.pidfd) urd.unimplemented("clone: pidfd");
    if (flags.ptrace) urd.unimplemented("clone: ptrace");
    if (flags.parent) urd.unimplemented("clone: share parent");

    if (flags.thread and !flags.sighand) return .err(.inval);
    if (flags.sighand and !flags.vm) return .err(.inval);

    const ch_flags = std.mem.zeroInit(task.CloneFlags, .{
        .vm = flags.vm,
        .suspend_parent = flags.vfork,
        .thread = flags.thread,
        .sighand = flags.sighand,
    });
    const child = task.clone(
        ch_flags,
        stack,
    ) catch return .err(.nomem);

    return .success(@bitCast(@as(u64, child.id)));
}

/// syscall: fork
pub fn sysFork() ReturnType {
    const child = task.clone(.{
        .vm = false,
        .suspend_parent = false,
        .thread = false,
        .sighand = false,
    }, 0) catch return .err(.nomem);

    return .success(@bitCast(@as(u64, child.tgid)));
}

/// syscall: vfork
pub fn sysVfork() ReturnType {
    const child = task.clone(.{
        .vm = true,
        .suspend_parent = true,
        .thread = false,
        .sighand = false,
    }, 0) catch return .err(.nomem);

    return .success(@bitCast(@as(u64, child.tgid)));
}

/// Linux compatible flags for clone syscall.
const CloneFlags = packed struct(u64) {
    /// Signal to send to the parent on child termination.
    csignal: u8,
    /// Share VM.
    vm: bool,
    /// Share FS info.
    fs: bool,
    /// Shares open files.
    files: bool,
    /// Share signal handlers and blocked signals.
    sighand: bool,
    /// A pidfd should be placed in parent.
    pidfd: bool,
    /// Continue tracing in the child.
    ptrace: bool,
    /// Suspend the parent until the child exits or calls execve.
    vfork: bool,
    /// Have the same parent as the cloner.
    parent: bool,
    /// Have the same thread group.
    thread: bool,
    /// Reserved.
    _17: u47 = 0,
};

/// syscall: execve
pub fn sysExecve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) ReturnType {
    const max_argv = 128;
    const max_envp = 128;

    // Construct argv and envp arrays.
    var args: [max_argv][]const u8 = undefined;
    var envs: [max_envp][]const u8 = undefined;

    var argc: usize = 0;
    while (argv[argc]) |arg| : (argc += 1) {
        if (argc == max_argv) {
            return .err(.toobig);
        }
        args[argc] = std.mem.span(arg);
    }
    var envc: usize = 0;
    while (envp[envc]) |env| : (envc += 1) {
        if (envc == max_envp) {
            return .err(.toobig);
        }
        envs[envc] = std.mem.span(env);
    }

    urd.task.execve(
        std.mem.span(path),
        args[0..argc],
        envs[0..envc],
    ) catch |err| return switch (err) {
        error.InvalidArgument => .err(.inval),
        error.OutOfMemory => .err(.nomem),
        error.InvalidElf, error.NotSupported => .err(.noexec),
        error.NotFound => .err(.noent),
        error.NotDirectory => .err(.notdir),
        else => .err(.inval),
    };

    unreachable;
}

/// syscall: set_tid_address
pub fn sysSetTidAddress(_: usize) ReturnType {
    return .err(.nosys);
}

/// syscall: arch_prctl
pub fn sysArchPrctl(op: ArchPrctlOp, addr: u64) ReturnType {
    switch (op) {
        .set_fs => {
            arch.thread.setThreadPointer(addr);
            return .success(0);
        },
        else => return .err(.inval),
    }
}

/// Operations for arch_prctl syscall.
const ArchPrctlOp = enum(u32) {
    /// Set the 64-bit base for the FS register.
    set_fs = 0x1002,

    _,
};

/// syscall: getpid
pub fn sysGetPid() ReturnType {
    const current = sched.getCurrent();
    return .success(@bitCast(@as(u64, current.tgid)));
}

/// syscall: getppid
pub fn sysGetPpid() ReturnType {
    const current = sched.getCurrent();
    return .success(@bitCast(@as(u64, current.ppid)));
}

/// syscall: gettid
pub fn sysGetTid() ReturnType {
    const current = sched.getCurrent();
    return .success(@bitCast(@as(u64, current.id)));
}

/// syscall: getuid
pub fn sysGetUid() ReturnType {
    return .success(0);
}

/// syscall: geteuid
pub fn sysGetEuid() ReturnType {
    return .success(0);
}

/// syscall: setpgid
pub fn sysSetPgid(pid: i32, pgid: i32) ReturnType {
    const cur = sched.getCurrent();
    if (pid != 0 and @as(u32, @bitCast(pid)) != cur.tgid) {
        return .err(.perm);
    }
    if (pgid < 0) {
        return .err(.inval);
    }
    // Session leaders cannot change their pgid.
    if (cur.tgid == cur.sid) {
        return .err(.perm);
    }
    cur.pgid = if (pgid == 0) cur.tgid else @bitCast(pgid);

    return .success(0);
}

/// syscall: getpgid
pub fn sysGetPgid(pid: i32) ReturnType {
    const cur = sched.getCurrent();
    if (pid != 0 and @as(u32, @bitCast(pid)) != cur.tgid) {
        return .err(.perm);
    }
    return .success(@intCast(cur.pgid));
}

/// syscall: setsid
pub fn sysSetsid() ReturnType {
    const cur = sched.getCurrent();
    if (cur.tgid == cur.pgid) {
        // Already a process group leader.
        return .err(.perm);
    }
    cur.sid = cur.tgid;
    cur.pgid = cur.tgid;

    return .success(@intCast(cur.sid));
}

/// syscall: getsid
pub fn sysGetsid(pid: i32) ReturnType {
    const cur = sched.getCurrent();
    if (pid != 0 and @as(u32, @bitCast(pid)) != cur.tgid) {
        return .err(.perm);
    }

    return .success(@intCast(cur.sid));
}

/// syscall: reboot
pub fn sysReboot(magic1: u32, magic2: RebootMagic2, cmd: RebootCmd, _: ?*anyopaque) ReturnType {
    if (magic1 != reboot_magic1) {
        return .err(.inval);
    }
    switch (magic2) {
        .a, .b, .c, .d => {},
        _ => return .err(.inval),
    }

    return switch (cmd) {
        .restart,
        .restart2,
        => {
            board.reset(0);
            while (true) arch.halt();
        },
        .power_off,
        .halt,
        => board.powerOff(),

        .cad_off,
        .cad_on,
        => .success(0),

        _ => .err(.inval),
    };
}

/// First magic value required by the `reboot` syscall.
const reboot_magic1: u32 = 0xfee1dead;
/// Second magic value required by the `reboot` syscall.
const RebootMagic2 = enum(u32) {
    a = 0x28121969,
    b = 0x05121996,
    c = 0x16041998,
    d = 0x20112000,

    _,
};

/// Commands for the `reboot` syscall.
const RebootCmd = enum(u32) {
    /// Disable CAD (Ctrl+Alt+Del) handling.
    cad_off = 0,
    /// Enable CAD (Ctrl+Alt+Del) handling.
    cad_on = 0x89ABCDEF,
    /// The message "Restarting system." is printed, and a default restart is performed immediately.
    restart = 0x01234567,
    /// The message "System halted" is printed, and the system is halted.
    halt = 0xCDEF0123,
    /// The message "Power down" is printed, and the system is powered down.
    power_off = 0x4321FEDC,
    /// The message "Restarting system with command '%s'" is printed, and a restart is performed immediately.
    restart2 = 0xA1B2C3D4,

    _,
};

/// syscall: prlimit64
pub fn sysPrlimit64(pid: i32, resource: i32, new_rlim: usize, old_rlim: usize) ReturnType {
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
const board = @import("board").impl;
const urd = @import("urthr");
const sched = urd.sched;
const task = urd.task;
const arch = @import("arch").impl;
const sig = urd.task.signal;
const ReturnType = urd.syscall.ReturnType;
