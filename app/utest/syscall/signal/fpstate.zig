/// Number of vector registers.
const num_vregs = switch (builtin.cpu.arch) {
    .x86_64 => 16, // XMM0-XMM15
    .aarch64 => 32, // V0-V31
    else => @compileError("Unsupported architecture."),
};

/// Contents of all vector registers.
const VregSet = [num_vregs][16]u8;

/// Generate contents of vector registers unique per register.
fn makeVregs(comptime invert: bool) VregSet {
    var set: VregSet = undefined;
    for (&set, 0..) |*reg, i| {
        for (reg, 0..) |*byte, j| {
            const v: u8 = @truncate(i * 31 + j * 7 + 1);
            byte.* = if (invert) ~v else v;
        }
    }
    return set;
}

/// Contents loaded before the signal is raised.
const pattern: VregSet align(16) = makeVregs(false);
/// Contents loaded by the signal handler.
const clobber: VregSet align(16) = makeVregs(true);

test "signal handler does not clobber the original FPU registers" {
    // Set signal handler.
    const sa: linux.Sigaction = .{
        .handler = .{ .handler = onSignalClobber },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.sigaction(.USR1, &sa, null),
    ));
    handler_called = false;

    // Raise the signal and read-back the vector registers.
    const pid: usize = @intCast(linux.getpid());
    const usr1: usize = @backingInt(linux.SIG.USR1);
    var after: VregSet align(16) = undefined;
    raiseKeepingRegs(pid, usr1, &after);

    // Check if the signal handler did not clobber the original FPU registers.
    var ok = true;
    try testing.expect(handler_called);
    for (pattern, after, 0..) |expected, actual, i| {
        testing.expectEqualSlices(u8, &expected, &actual) catch {
            std.log.err("Vector register #{d} is clobbered.", .{i});
            ok = false;
        };
    }
    try testing.expect(ok);
}

var handler_called: bool = false;

/// Signal handler that overwrites all vector registers.
fn onSignalClobber(_: linux.SIG) callconv(.c) void {
    const src: *const VregSet align(16) = &clobber;
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (loadRegs("r8")
            :
            : [src] "{r8}" (src),
            : vregClobbers(.{ .memory = true })),
        .aarch64 => asm volatile (loadRegs("x9")
            :
            : [src] "{x9}" (src),
            : vregClobbers(.{ .memory = true })),
        else => @compileError("Unsupported architecture."),
    }
    handler_called = true;
}

/// Load the pattern into all vector registers, send a signal, and read back the registers.
fn raiseKeepingRegs(pid: usize, signo: usize, out: *align(16) VregSet) void {
    const src: *const VregSet align(16) = &pattern;
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (loadRegs("r8") ++ "syscall\n" ++ storeRegs("r9")
            :
            : [src] "{r8}" (src),
              [out] "{r9}" (out),
              [nr] "{rax}" (@as(usize, 62)), // kill syscall
              [pid] "{rdi}" (pid),
              [sig] "{rsi}" (signo),
            : vregClobbers(.{ .rax = true, .rcx = true, .r11 = true, .memory = true })),

        .aarch64 => asm volatile (loadRegs("x9") ++ "svc #0\n" ++ storeRegs("x10")
            :
            : [src] "{x9}" (src),
              [out] "{x10}" (out),
              [nr] "{x8}" (@as(usize, 129)), // kill syscall
              [pid] "{x0}" (pid),
              [sig] "{x1}" (signo),
            : vregClobbers(.{ .x0 = true, .memory = true })),

        else => @compileError("Unsupported architecture."),
    }
}

/// Assembly to load all vector registers from the buffer.
fn loadRegs(comptime r: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var asm_str: []const u8 = switch (builtin.cpu.arch) {
            .aarch64 => ".arch_extension simd\n",
            else => "",
        };
        for (0..num_vregs) |i| {
            asm_str = asm_str ++ switch (builtin.cpu.arch) {
                .x86_64 => std.fmt.comptimePrint("movdqa {d}(%%{s}), %%xmm{d}\n", .{ i * 16, r, i }),
                .aarch64 => std.fmt.comptimePrint("ldr q{d}, [{s}, #{d}]\n", .{ i, r, i * 16 }),
                else => unreachable,
            };
        }
        return asm_str;
    }
}

/// Assembly to store all vector registers into the buffer.
fn storeRegs(comptime r: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var asm_str: []const u8 = "";
        for (0..num_vregs) |i| {
            asm_str = asm_str ++ switch (builtin.cpu.arch) {
                .x86_64 => std.fmt.comptimePrint("movdqa %%xmm{d}, {d}(%%{s})\n", .{ i, i * 16, r }),
                .aarch64 => std.fmt.comptimePrint("str q{d}, [{s}, #{d}]\n", .{ i, r, i * 16 }),
                else => unreachable,
            };
        }
        return asm_str;
    }
}

/// Clobber list including all vector registers.
fn vregClobbers(comptime base: std.builtin.assembly.Clobbers) std.builtin.assembly.Clobbers {
    comptime {
        @setEvalBranchQuota(100_000);
        var clobbers = base;
        for (0..num_vregs) |i| {
            const name = switch (builtin.cpu.arch) {
                .x86_64 => std.fmt.comptimePrint("xmm{d}", .{i}),
                .aarch64 => std.fmt.comptimePrint("v{d}", .{i}),
                else => unreachable,
            };
            @field(clobbers, name) = true;
        }
        return clobbers;
    }
}

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
