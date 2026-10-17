test "illegal instruction terminates the process with SIGILL" {
    try utest.expectRunChildSignaled(.ILL, 0, struct {
        pub fn lambda(_: usize) noreturn {
            switch (builtin.cpu.arch) {
                .x86_64 => asm volatile ("ud2"),
                .aarch64 => asm volatile ("udf #0"),
                else => @compileError("Unsupported architecture."),
            }
            unreachable;
        }
    });
}

test "SIGILL handler receives the address of the faulting instruction" {
    try utest.expectRunChild(0, struct {
        pub fn lambda(_: usize) noreturn {
            // Set signal handler for SIGILL
            const sa: linux.Sigaction = .{
                .handler = .{ .sigaction = onSigIll },
                .mask = linux.sigemptyset(),
                .flags = linux.SA.SIGINFO,
            };
            _ = linux.sigaction(.ILL, &sa, null);

            // Raise an illegal instruction exception.
            const f: *const fn () callconv(.c) noreturn = @ptrCast(&illegalInstruction);
            f();
        }

        fn onSigIll(_: linux.SIG, info: *const linux.siginfo_t, _: ?*anyopaque) callconv(.c) void {
            const faulting_addr: usize = @intFromPtr(info.fields.sigfault.addr);
            linux.exit_group(if (faulting_addr == @intFromPtr(&illegalInstruction))
                0
            else
                1);
        }

        fn illegalInstruction() callconv(.naked) noreturn {
            switch (builtin.cpu.arch) {
                .x86_64 => asm volatile ("ud2"),
                .aarch64 => asm volatile ("udf #0"),
                else => @compileError("Unsupported architecture."),
            }
        }
    });
}

test "misaligned SSE access terminates the process with SIGSEGV" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    try utest.expectRunChildSignaled(.SEGV, 0, struct {
        pub fn lambda(_: usize) noreturn {
            var buf: [64]u8 align(16) = undefined;
            asm volatile ("movdqa (%[p]), %%xmm0"
                :
                : [p] "r" (@intFromPtr(&buf) + 1),
                : .{ .xmm0 = true });
            unreachable;
        }
    });
}

test "misaligned exclusive access terminates the process with SIGBUS" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    try utest.expectRunChildSignaled(.BUS, 0, struct {
        pub fn lambda(_: usize) noreturn {
            var buf: [16]u8 align(16) = undefined;
            asm volatile ("ldxr x0, [%[p]]"
                :
                : [p] "r" (@intFromPtr(&buf) + 1),
                : .{ .x0 = true });
            unreachable;
        }
    });
}

test "breakpoint instruction terminates the process with SIGTRAP" {
    try utest.expectRunChildSignaled(.TRAP, 0, struct {
        pub fn lambda(_: usize) noreturn {
            switch (builtin.cpu.arch) {
                .x86_64 => asm volatile ("int3"),
                .aarch64 => asm volatile ("brk #0"),
                else => @compileError("Unsupported architecture."),
            }
            unreachable;
        }
    });
}

test "instruction fetch from an unmapped address terminates the process with SIGSEGV" {
    try utest.expectRunChildSignaled(.SEGV, 0, struct {
        pub fn lambda(_: usize) noreturn {
            const f: *const fn () callconv(.c) void = @ptrFromInt(0x1000);
            f();
            unreachable;
        }
    });
}

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const linux = @import("std").os.linux;
const utest = @import("utest");
