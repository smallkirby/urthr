// zig fmt: off

/// List of system calls.
///
/// NOTE that this table is referenced only at comptime to construct runtime constants.
///
/// TODO: should be arch-specific.
const entries = [_]Descriptor{
    // =============================================================
    // POSIX system calls.

    .new("write",       64,     posix.fs.sysWrite),
    .new("writev",      66,     posix.fs.sysWritev),
    .new("exit_group",  94,     posix.task.sysExitGroup),
    .new("brk",         214,    posix.task.sysBrk),

    // =============================================================
    // Debug system calls.

    .new("ping",        512,    sysPing),
};

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

    pub fn success(value: i64) ReturnType {
        return .{ ._s = value };
    }

    pub fn err(e: ErrorEnum) ReturnType {
        return .{ ._e = e };
    }

    pub fn int(self: ReturnType) i64 {
        return switch (self) {
            ._s => self._s,
            ._e => @intFromEnum(self._e),
        };
    }
};

/// Initialize syscall subsystem.
pub fn init() void {
    arch.setSystemCallHandler(invoke);
}

/// Call a system call handler corresponding to the given syscall number.
fn invoke(nr: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) i64 {
    if (nr >= num_syscall) {
        return @intFromEnum(ErrorEnum.nosys);
    }

    const ret = if (syscall_table[nr]) |handler| handler.f(
        arg1,
        arg2,
        arg3,
        arg4,
        arg5,
        arg6,
    ) else {
        log.debug("Unhandled syscall: {d}", .{nr});
        return @intFromEnum(ErrorEnum.nosys);
    };

    return ret.int();
}

/// System call: ping
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
            else => @compileError(std.fmt.comptimePrint("convert(): Invalid type: {s}", .{@typeName(T)})),
        };
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.syscall);
const arch = @import("arch").impl;
const urd = @import("urthr");
const posix = urd.posix;
const ErrorEnum = posix.ErrorEnum;
