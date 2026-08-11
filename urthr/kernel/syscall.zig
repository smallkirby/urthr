// zig fmt: off

/// List of system calls.
///
/// NOTE that this table is referenced only at comptime to construct runtime constants.
const entries =
// =============================================================
// Aarch64
// =============================================================
if (builtin.cpu.arch.isAARCH64())[_]Descriptor{
    // =============================================================
    // POSIX system calls.

    .new("getcwd",              17,     posix.fs.sysGetCwd),
    .new("dup",                 23,     posix.fs.sysDup),
    .new("dup3",                24,     posix.fs.sysDup3),
    .new("fcntl",               25,     posix.fs.sysFcntl),
    .new("ioctl",               29,     posix.fs.sysIoctl),
    .new("mkdirat",             34,     posix.fs.sysMkdirAt),
    .new("unlinkat",            35,     posix.fs.sysUnlinkAt),
    .new("mount",               40,     posix.fs.sysMount),
    .new("ftruncate",           46,     posix.fs.sysFtruncate),
    .new("faccessat",           48,     posix.fs.sysFaccessAt),
    .new("chdir",               49,     posix.fs.sysChdir),
    .new("fchdir",              50,     posix.fs.sysFchdir),
    .new("fchmodat",            53,     posix.fs.sysFchmodAt),
    .new("openat",              56,     posix.fs.sysOpenAt),
    .new("pipe2",               59,     posix.fs.sysPipe2),
    .new("close",               57,     posix.fs.sysClose),
    .new("getdents64",          61,     posix.fs.sysGetDents64),
    .new("lseek",               62,     posix.fs.sysLseek),
    .new("read",                63,     posix.fs.sysRead),
    .new("write",               64,     posix.fs.sysWrite),
    .new("readv",               65,     posix.fs.sysReadv),
    .new("writev",              66,     posix.fs.sysWritev),
    .new("preadv",              69,     posix.fs.sysPreadv),
    .new("pwritev",             70,     posix.fs.sysPwritev),
    .new("ppoll",               73,     posix.fs.sysPpoll),
    .new("newfstatat",          79,     posix.fs.sysNewFstatAt),
    .new("fstat",               80,     posix.fs.sysFstat),
    .new("exit",                93,     posix.task.sysExit),
    .new("exit_group",          94,     posix.task.sysExitGroup),
    .new("set_tid_address",     96,     posix.task.sysSetTidAddress),
    .new("nanosleep",           101,    posix.time.sysNanoSleep),
    .new("wait4",               260,    posix.task.sysWait4),
    .new("clock_gettime",       113,    posix.time.sysClockGetTime),
    .new("clock_nanosleep",     115,    posix.time.sysClockNanoSleep),
    .new("sched_getaffinity",   123,    posix.sched.sysSchedGetAffinity),
    .new("sched_yield",         124,    posix.sched.sysSchedYield),
    .new("kill",                129,    posix.signal.sysKill),
    .new("rt_sigreturn",        139,    posix.signal.sysRtSigReturn),
    .new("sigaltstack",         132,    posix.signal.sysSigAltStack),
    .new("rt_sigaction",        134,    posix.signal.sysRtSigAction),
    .new("rt_sigprocmask",      135,    posix.signal.sysRtSigProcMask),
    .new("reboot",              142,    posix.task.sysReboot),
    .new("setpgid",             154,    posix.task.sysSetPgid),
    .new("getpgid",             155,    posix.task.sysGetPgid),
    .new("getsid",              156,    posix.task.sysGetsid),
    .new("setsid",              157,    posix.task.sysSetsid),
    .new("uname",               160,    posix.system.sysUname),
    .new("sethostname",         161,    posix.system.sysSetHostname),
    .new("umask",               166,    posix.fs.sysUmask),
    .new("getpid",              172,    posix.task.sysGetPid),
    .new("getppid",             173,    posix.task.sysGetPpid),
    .new("getuid",              174,    posix.task.sysGetUid),
    .new("geteuid",             175,    posix.task.sysGetEuid),
    .new("gettid",              178,    posix.task.sysGetTid),
    .new("socket",              198,    posix.net.sysSocket),
    .new("bind",                200,    posix.net.sysBind),
    .new("connect",             203,    posix.net.sysConnect),
    .new("sendto",              206,    posix.net.sysSendTo),
    .new("recvfrom",            207,    posix.net.sysRecvFrom),
    .new("setsockopt",          208,    posix.net.sysSetSockOpt),
    .new("getsockopt",          209,    posix.net.sysGetSockOpt),
    .new("shutdown",            210,    posix.net.sysShutdown),
    .new("recvmsg",             212,    posix.net.sysRecvMsg),
    .new("brk",                 214,    posix.mem.sysBrk),
    .new("munmap",              215,    posix.mem.sysMunmap),
    .new("clone",               220,    posix.task.sysClone),
    .new("execve",              221,    posix.task.sysExecve),
    .new("mmap",                222,    posix.mem.sysMmap),
    .new("mprotect",            226,    posix.mem.sysMprotect),
    .new("prlimit64",           261,    posix.task.sysPrlimit64),
    .new("statx",               291,    posix.fs.sysStatx),

    // =============================================================
    // Debug system calls.

    .new("ping",        512,    sysPing),
}

// =============================================================
// x64
// =============================================================
else if (builtin.cpu.arch.isX86())[_]Descriptor{
    // =============================================================
    // POSIX system calls.

    .new("read",                  0,    posix.fs.sysRead),
    .new("write",                 1,    posix.fs.sysWrite),
    .new("open",                  2,    posix.fs.sysOpen),
    .new("close",                 3,    posix.fs.sysClose),
    .new("stat",                  4,    posix.fs.sysStat),
    .new("fstat",                 5,    posix.fs.sysFstat),
    .new("lstat",                 6,    posix.fs.sysLstat),
    .new("poll",                  7,    posix.fs.sysPoll),
    .new("lseek",                 8,    posix.fs.sysLseek),
    .new("mmap",                  9,    posix.mem.sysMmap),
    .new("mprotect",             10,    posix.mem.sysMprotect),
    .new("munmap",               11,    posix.mem.sysMunmap),
    .new("brk",                  12,    posix.mem.sysBrk),
    .new("rt_sigaction",         13,    posix.signal.sysRtSigAction),
    .new("rt_sigprocmask",       14,    posix.signal.sysRtSigProcMask),
    .new("rt_sigreturn",         15,    posix.signal.sysRtSigReturn),
    .new("ioctl",                16,    posix.fs.sysIoctl),
    .new("readv",                19,    posix.fs.sysReadv),
    .new("writev",               20,    posix.fs.sysWritev),
    .new("access",               21,    posix.fs.sysAccess),
    .new("pipe",                 22,    posix.fs.sysPipe),
    .new("sched_yield",          24,    posix.sched.sysSchedYield),
    .new("dup",                  32,    posix.fs.sysDup),
    .new("dup2",                 33,    posix.fs.sysDup2),
    .new("nanosleep",            35,    posix.time.sysNanoSleep),
    .new("setitimer",            38,    posix.time.sysSetItimer),
    .new("getpid",               39,    posix.task.sysGetPid),
    .new("socket",               41,    posix.net.sysSocket),
    .new("connect",              42,    posix.net.sysConnect),
    .new("sendto",               44,    posix.net.sysSendTo),
    .new("recvfrom",             45,    posix.net.sysRecvFrom),
    .new("recvmsg",              47,    posix.net.sysRecvMsg),
    .new("shutdown",             48,    posix.net.sysShutdown),
    .new("bind",                 49,    posix.net.sysBind),
    .new("setsockopt",           54,    posix.net.sysSetSockOpt),
    .new("getsockopt",           55,    posix.net.sysGetSockOpt),
    .new("clone",                56,    posix.task.sysClone),
    .new("fork",                 57,    posix.task.sysFork),
    .new("vfork",                58,    posix.task.sysVfork),
    .new("execve",               59,    posix.task.sysExecve),
    .new("exit",                 60,    posix.task.sysExit),
    .new("wait4",                61,    posix.task.sysWait4),
    .new("kill",                 62,    posix.signal.sysKill),
    .new("uname",                63,    posix.system.sysUname),
    .new("fcntl",                72,    posix.fs.sysFcntl),
    .new("ftruncate",            77,    posix.fs.sysFtruncate),
    .new("getcwd",               79,    posix.fs.sysGetCwd),
    .new("chdir",                80,    posix.fs.sysChdir),
    .new("fchdir",               81,    posix.fs.sysFchdir),
    .new("mkdir",                83,    posix.fs.sysMkdir),
    .new("unlink",               87,    posix.fs.sysUnlink),
    .new("umask",                95,    posix.fs.sysUmask),
    .new("getuid",               102,   posix.task.sysGetUid),
    .new("geteuid",              107,   posix.task.sysGetEuid),
    .new("setpgid",              109,   posix.task.sysSetPgid),
    .new("getppid",              110,   posix.task.sysGetPpid),
    .new("setsid",               112,   posix.task.sysSetsid),
    .new("getpgid",              121,   posix.task.sysGetPgid),
    .new("getsid",               124,   posix.task.sysGetsid),
    .new("sigaltstack",          131,   posix.signal.sysSigAltStack),
    .new("arch_prctl",           158,   posix.task.sysArchPrctl),
    .new("mount",                165,   posix.fs.sysMount),
    .new("reboot",               169,   posix.task.sysReboot),
    .new("sethostname",          170,   posix.system.sysSetHostname),
    .new("gettid",               186,   posix.task.sysGetTid),
    .new("sched_getaffinity",    204,   posix.sched.sysSchedGetAffinity),
    .new("set_tid_address",      218,   posix.task.sysSetTidAddress),
    .new("getdents64",           217,   posix.fs.sysGetDents64),
    .new("clock_gettime",        228,   posix.time.sysClockGetTime),
    .new("clock_nanosleep",      230,   posix.time.sysClockNanoSleep),
    .new("exit_group",           231,   posix.task.sysExitGroup),
    .new("openat",               257,   posix.fs.sysOpenAt),
    .new("mkdirat",              258,   posix.fs.sysMkdirAt),
    .new("newfstatat",           262,   posix.fs.sysNewFstatAt),
    .new("unlinkat",             263,   posix.fs.sysUnlinkAt),
    .new("fchmodat",             268,   posix.fs.sysFchmodAt),
    .new("faccessat",            269,   posix.fs.sysFaccessAt),
    .new("ppoll",                271,   posix.fs.sysPpoll),
    .new("dup3",                 292,   posix.fs.sysDup3),
    .new("pipe2",                293,   posix.fs.sysPipe2),
    .new("preadv",               295,   posix.fs.sysPreadv),
    .new("pwritev",              296,   posix.fs.sysPwritev),
    .new("prlimit64",            302,   posix.task.sysPrlimit64),
    .new("statx",                332,   posix.fs.sysStatx),

    // =============================================================
    // Debug system calls.

    .new("ping",                 512,   sysPing),
}
else [_]Descriptor{}
;

// zig fmt: on

/// The number of system calls.
const num_syscall = 1024;

/// System call handler function type.
const HandlerFn = *const fn (u64, u64, u64, u64, u64, u64) ReturnType;

/// Return type of system calls.
pub const ReturnType = union(enum) {
    /// Success value.
    _s: i64,
    /// Error value.
    _e: ErrorEnum,
    /// Arch-specific syscall handler should use the value in the saved context as return value.
    _nop: void,

    pub fn success(value: i64) ReturnType {
        return .{ ._s = value };
    }

    pub fn err(e: ErrorEnum) ReturnType {
        return .{ ._e = e };
    }

    pub fn nop() ReturnType {
        return .{ ._nop = {} };
    }

    pub fn int(self: ReturnType) ?i64 {
        return switch (self) {
            ._s => |v| v,
            ._e => |e| @intFromEnum(e),
            ._nop => null,
        };
    }
};

/// Initialize syscall subsystem.
pub fn init() void {
    arch.setSystemCallHandler(invoke);
    arch.setEreturnHook(urd.task.signal.deliver);
    arch.initSyscall();
}

/// Call a system call handler corresponding to the given syscall number.
fn invoke(nr: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) ?i64 {
    if (nr >= num_syscall) {
        return @intFromEnum(ErrorEnum.nosys);
    }

    trace("call: {d} ({s})", .{ nr, std.enums.tagName(SyscallEnum, @enumFromInt(nr)) orelse "unknown" });

    const ret = if (syscall_table[nr]) |handler| handler.f(
        arg1,
        arg2,
        arg3,
        arg4,
        arg5,
        arg6,
    ) else {
        log.warn("Unhandled syscall: {d}", .{nr});
        return @intFromEnum(ErrorEnum.nosys);
    };

    return ret.int();
}

/// syscall: ping
fn sysPing() ReturnType {
    log.debug("pong", .{});

    return .success(0);
}

// =============================================================
// Constants
// =============================================================

/// Table of system calls.
///
/// This table is referenced at runtime to dispatch a system call handler.
/// A key corresponds to a syscall number.
const syscall_table: [num_syscall]?SyscallHandler = blk: {
    @setEvalBranchQuota(num_syscall * 2);

    var table: [num_syscall]?SyscallHandler = undefined;

    // Init all handlers as unhandled.
    for (0..num_syscall) |i| {
        table[i] = null;
    }

    // Iterate over syscall enum and assign a corresponding handler.
    for (entries) |entry| {
        const nr = entry.nr;
        table[nr] = entry.handler;
    }

    break :blk table;
};

/// System call enum.
///
/// This enum is constructed at compile time referring to the syscall entries.
const SyscallEnum = blk: {
    @setEvalBranchQuota(num_syscall * 4);

    var names: [entries.len][]const u8 = undefined;
    var values: [entries.len]u64 = undefined;

    for (entries, 0..) |entry, i| {
        names[i] = entry.name;
        values[i] = entry.nr;
    }

    break :blk @Enum(
        u64,
        .nonexhaustive,
        &names,
        &values,
    );
};

// =============================================================
// Internals
// =============================================================

/// System call descriptor.
const Descriptor = struct {
    /// Syscall name.
    name: [:0]const u8,
    /// System call number.
    nr: u64,
    /// System call handler.
    handler: SyscallHandler,

    /// Create a new system call descriptor.
    fn new(comptime name: [:0]const u8, comptime nr: u64, comptime handler: anytype) Descriptor {
        return Descriptor{
            .name = name,
            .nr = nr,
            .handler = .new(handler),
        };
    }
};

/// System call handler union.
const SyscallHandler = struct {
    f: HandlerFn,

    /// Create a syscall handler.
    fn new(comptime handler: anytype) SyscallHandler {
        return SyscallHandler{ .f = sys(handler) };
    }

    /// Generate a wrapper function for the syscall handler.
    ///
    /// This function converts an syscall handler function to the fixed signature `NormalHandler`.
    fn sys(comptime handler: anytype) HandlerFn {
        const func = @typeInfo(@TypeOf(handler)).@"fn";

        const S = struct {
            inline fn ArgType(comptime i: usize) type {
                return func.params[i].type orelse @compileError("sys(): Invalid parameter type");
            }

            fn f0(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) ReturnType {
                return handler();
            }
            fn f1(arg1: u64, _: u64, _: u64, _: u64, _: u64, _: u64) ReturnType {
                return handler(convert(ArgType(0), arg1));
            }
            fn f2(arg1: u64, arg2: u64, _: u64, _: u64, _: u64, _: u64) ReturnType {
                return handler(convert(ArgType(0), arg1), convert(ArgType(1), arg2));
            }
            fn f3(arg1: u64, arg2: u64, arg3: u64, _: u64, _: u64, _: u64) ReturnType {
                return handler(convert(ArgType(0), arg1), convert(ArgType(1), arg2), convert(ArgType(2), arg3));
            }
            fn f4(arg1: u64, arg2: u64, arg3: u64, arg4: u64, _: u64, _: u64) ReturnType {
                return handler(convert(ArgType(0), arg1), convert(ArgType(1), arg2), convert(ArgType(2), arg3), convert(ArgType(3), arg4));
            }
            fn f5(arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, _: u64) ReturnType {
                return handler(convert(ArgType(0), arg1), convert(ArgType(1), arg2), convert(ArgType(2), arg3), convert(ArgType(3), arg4), convert(ArgType(4), arg5));
            }
            fn f6(arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) ReturnType {
                return handler(convert(ArgType(0), arg1), convert(ArgType(1), arg2), convert(ArgType(2), arg3), convert(ArgType(3), arg4), convert(ArgType(4), arg5), convert(ArgType(5), arg6));
            }
        };

        return switch (func.params.len) {
            0 => return S.f0,
            1 => return S.f1,
            2 => return S.f2,
            3 => return S.f3,
            4 => return S.f4,
            5 => return S.f5,
            6 => return S.f6,
            else => @compileError("Wrapper: Invalid number of parameters"),
        };
    }

    /// Convert a syscall argument to the expected type.
    fn convert(comptime T: type, arg: u64) T {
        return switch (@typeInfo(T)) {
            .pointer => @ptrFromInt(arg),
            .int => switch (@bitSizeOf(T)) {
                8 => @bitCast(@as(u8, @truncate(arg))),
                16 => @bitCast(@as(u16, @truncate(arg))),
                32 => @bitCast(@as(u32, @truncate(arg))),
                64 => @bitCast(@as(u64, @truncate(arg))),
                else => @compileError("convert(): Invalid integer size"),
            },
            .@"enum" => |t| switch (@bitSizeOf(t.tag_type)) {
                8 => @enumFromInt(@as(t.tag_type, @bitCast(@as(u8, @truncate(arg))))),
                16 => @enumFromInt(@as(t.tag_type, @bitCast(@as(u16, @truncate(arg))))),
                32 => @enumFromInt(@as(t.tag_type, @bitCast(@as(u32, @truncate(arg))))),
                64 => @enumFromInt(@as(t.tag_type, @bitCast(@as(u64, @truncate(arg))))),
                else => @compileError("convert(): Invalid enum size"),
            },
            .@"struct" => switch (@bitSizeOf(T)) {
                8 => @bitCast(@as(u8, @truncate(arg))),
                16 => @bitCast(@as(u16, @truncate(arg))),
                32 => @bitCast(@as(u32, @truncate(arg))),
                64 => @bitCast(@as(u64, @truncate(arg))),
                else => @compileError("convert(): Invalid struct size"),
            },
            .optional => |opt| switch (@typeInfo(opt.child)) {
                .pointer => if (arg == 0) null else @ptrFromInt(arg),
                else => @compileError(std.fmt.comptimePrint("convert(): Invalid optional type: {s}", .{@typeName(T)})),
            },
            else => @compileError(std.fmt.comptimePrint("convert(): Invalid type: {s}", .{@typeName(T)})),
        };
    }
};

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.syscall);
const arch = @import("arch").impl;
const urd = @import("urthr");
const trace = urd.trace.scoped(.syscall, .syscall);
const posix = urd.posix;
const ErrorEnum = posix.ErrorEnum;
