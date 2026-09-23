const num_threads = 4;
const iterations = 100;
const num_fpu = switch (builtin.cpu.arch) {
    .x86_64 => 16,
    else => 0,
};
const bytes_fpu = switch (builtin.cpu.arch) {
    .x86_64 => 32,
    else => 0,
};

const FpuState = [num_fpu * bytes_fpu]u8;

const S = struct {
    var corrupted = [_]std.atomic.Value(bool){.init(false)} ** num_threads;
    var done = [_]std.atomic.Value(bool){.init(false)} ** num_threads;

    fn threadMain(idx: usize) callconv(.c) u8 {
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            // Construct FPU values unique to this thread and iteration.
            const pattern = buildPattern(idx, i);

            // Load the constructed values into FPU and yield to allow context switch.
            var readback: FpuState = undefined;
            yield(&pattern, &readback);

            // Check if the current FPU state matches the pattern.
            if (!std.mem.eql(u8, &pattern, &readback)) {
                S.corrupted[idx].store(true, .release);
            }
        }
        S.done[idx].store(true, .release);
        linux.exit(0);
    }
};

/// Builds FPU registers unique to this thread and iteration.
fn buildPattern(idx: usize, iter: usize) FpuState {
    const HashTarget = struct {
        idx: usize,
        iter: usize,
        reg: usize,
        byte: usize,
    };
    const Hasher = std.hash.Wyhash;

    var state: FpuState = undefined;
    for (0..num_fpu) |reg| {
        for (0..bytes_fpu) |byte| {
            const target = HashTarget{
                .idx = idx,
                .iter = iter,
                .reg = reg,
                .byte = byte,
            };
            state[reg * bytes_fpu + byte] = @truncate(Hasher.hash(
                0,
                std.mem.asBytes(&target),
            ));
        }
    }
    return state;
}

/// Loads FPU values into registers, then yields to allow a context switch.
fn yield(pattern: *const FpuState, out: *FpuState) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\vmovdqu ( 0*32)(%[p]), %%ymm0
            \\vmovdqu ( 1*32)(%[p]), %%ymm1
            \\vmovdqu ( 2*32)(%[p]), %%ymm2
            \\vmovdqu ( 3*32)(%[p]), %%ymm3
            \\vmovdqu ( 4*32)(%[p]), %%ymm4
            \\vmovdqu ( 5*32)(%[p]), %%ymm5
            \\vmovdqu ( 6*32)(%[p]), %%ymm6
            \\vmovdqu ( 7*32)(%[p]), %%ymm7
            \\vmovdqu ( 8*32)(%[p]), %%ymm8
            \\vmovdqu ( 9*32)(%[p]), %%ymm9
            \\vmovdqu (10*32)(%[p]), %%ymm10
            \\vmovdqu (11*32)(%[p]), %%ymm11
            \\vmovdqu (12*32)(%[p]), %%ymm12
            \\vmovdqu (13*32)(%[p]), %%ymm13
            \\vmovdqu (14*32)(%[p]), %%ymm14
            \\vmovdqu (15*32)(%[p]), %%ymm15
            \\
            \\syscall
            \\
            \\vmovdqu %%ymm0,  ( 0*32)(%[out])
            \\vmovdqu %%ymm1,  ( 1*32)(%[out])
            \\vmovdqu %%ymm2,  ( 2*32)(%[out])
            \\vmovdqu %%ymm3,  ( 3*32)(%[out])
            \\vmovdqu %%ymm4,  ( 4*32)(%[out])
            \\vmovdqu %%ymm5,  ( 5*32)(%[out])
            \\vmovdqu %%ymm6,  ( 6*32)(%[out])
            \\vmovdqu %%ymm7,  ( 7*32)(%[out])
            \\vmovdqu %%ymm8,  ( 8*32)(%[out])
            \\vmovdqu %%ymm9,  ( 9*32)(%[out])
            \\vmovdqu %%ymm10, (10*32)(%[out])
            \\vmovdqu %%ymm11, (11*32)(%[out])
            \\vmovdqu %%ymm12, (12*32)(%[out])
            \\vmovdqu %%ymm13, (13*32)(%[out])
            \\vmovdqu %%ymm14, (14*32)(%[out])
            \\vmovdqu %%ymm15, (15*32)(%[out])
            :
            : [p] "r" (pattern),
              [out] "r" (out),
              [nr] "{rax}" (@intFromEnum(linux.SYS.sched_yield)),
            : .{
              .memory = true,
              .rax = true,
              .rcx = true,
              .r11 = true,
              .ymm0 = true,
              .ymm1 = true,
              .ymm2 = true,
              .ymm3 = true,
              .ymm4 = true,
              .ymm5 = true,
              .ymm6 = true,
              .ymm7 = true,
              .ymm8 = true,
              .ymm9 = true,
              .ymm10 = true,
              .ymm11 = true,
              .ymm12 = true,
              .ymm13 = true,
              .ymm14 = true,
              .ymm15 = true,
            }),

        else => unreachable,
    }
}

test "context switch preserves FPU registers across context switches" {
    switch (builtin.cpu.arch) {
        .x86_64 => {},
        else => return error.SkipZigTest,
    }

    for (0..num_threads) |i| {
        S.corrupted[i].store(false, .release);
        S.done[i].store(false, .release);
    }

    for (0..num_threads) |i| {
        _ = try utest.task.spawnThread(S.threadMain, i);
    }

    // Wait for all threads to finish.
    while (true) {
        var all_done = true;
        for (0..num_threads) |i| {
            if (!S.done[i].load(.acquire)) all_done = false;
        }
        if (all_done) break;
        _ = linux.sched_yield();
    }

    for (0..num_threads) |i| {
        try testing.expect(!S.corrupted[i].load(.acquire));
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
