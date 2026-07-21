/// The number of signals supported.
pub const num_signals = 64;

/// Integer type for signal numbers.
const SigInt = u32;

/// Signal numbers.
///
/// POSIX-compliant.
const Signal = enum(SigInt) {
    /// Hangup detected on controlling terminal or death of controlling process.
    hang = 1,
    /// Interrupt from keyboard.
    interrupt = 2,
    /// Quit from keyboard.
    quit = 3,
    /// Kill signal.
    kill = 9,
    /// Segmentation fault.
    segv = 11,
    /// Broken pipe.
    pipe = 13,
    /// Termination signal.
    term = 15,
    /// Child stopped or terminated.
    child = 17,
    /// Continue if stopped.
    cont = 18,
    /// Stop process.
    stop = 19,
    /// Terminal stop signal.
    tstp = 20,
    /// Background process attempting read.
    ttin = 21,
    /// Background process attempting write.
    ttou = 22,
};
comptime {
    for (std.enums.values(Signal)) |sig| {
        urd.comptimeAssert(@intFromEnum(sig) <= num_signals, "Invalid signal number.", .{});
    }
}

/// Bit mask type for signal sets.
pub const Mask = u64;
comptime {
    urd.comptimeAssert(@bitSizeOf(Mask) >= num_signals, "Mask type is too small.", .{});
}

/// Signal action descriptor.
pub const Action = struct {
    /// User-space handler address.
    handler: usize = sig_default,
    /// Additional signals to block while the handler runs.
    mask: Mask = 0,
    /// SA_* flags.
    flags: u32 = 0,

    /// Use default action for the given signal number.
    const sig_default: usize = 0;
    /// Ignore the given signal number.
    const sig_ignore: usize = 1;
};

/// Per-thread signal state.
pub const State = struct {
    /// Per-signal action table (0-origin).
    actions: [num_signals]Action = [_]Action{.{}} ** num_signals,
    /// Pending signals not yet delivered.
    pending: Mask = 0,
    /// Currently blocked signals.
    blocked: Mask = 0,
    /// User-space address of the sigreturn trampoline page.
    trampoline: ?usize = null,
};

/// Deliver all pending unblocked signals to the current thread.
pub fn deliver() void {
    const ctx = sched.getCurrentCtx();
    const th = sched.getCurrent();

    if (!isDeliverable(0, ctx)) {
        return;
    }

    while (true) {
        const deliverable = th.sigstate.pending & ~th.sigstate.blocked;
        if (deliverable == 0) break;

        const bit: u6 = @intCast(@ctz(deliverable));
        const signo: SigInt = bit + 1;
        const action = th.sigstate.actions[bit];

        // Clear pending bit.
        th.sigstate.pending &= ~(@as(Mask, 1) << bit);

        // Ignore if the handler is set to ignore.
        if (action.handler == Action.sig_ignore) continue;

        // Default action if the handler is set to default.
        if (action.handler == Action.sig_default) {
            getDefaultHandler(@enumFromInt(signo))();
            continue;
        }

        // Construct sigframe for user-space handler.
        setupSigFrame(ctx, th, signo, action) catch {
            log.err("Failed to setup sigframe for signal#{d}", .{signo});
            task.exit(-1);
        };
        th.sigstate.blocked |= action.mask | (@as(Mask, 1) << bit);

        // Remaining signals delivered on next return from kernel.
        break;
    }
}

/// Restore the user context from the sigframe.
pub fn sigreturn() void {
    const ctx = sched.getCurrentCtx();
    const th = sched.getCurrent();

    const mask = switch (builtin.cpu.arch) {
        .aarch64 => blk: {
            const frame: *const SigFrame = @ptrFromInt(ctx.sp_el0);

            // Restore x0–x30.
            const ctx_regs: *[31]u64 = @ptrCast(ctx);
            ctx_regs.* = frame.regs;
            // Restore SP, PC, PSTATE.
            ctx.sp_el0 = frame.sp;
            ctx.pc = frame.pc;
            ctx.pstate = frame.pstate;

            break :blk frame.saved_mask;
        },

        else => @compileError("Unsupported architecture."),
    };

    th.sigstate.blocked = mask;
}

/// Push a pending signal to the current thread.
pub fn push(signo: Signal) void {
    const th = sched.getCurrent();
    const bit: u6 = @intCast(@intFromEnum(signo) - 1);
    th.sigstate.pending |= @as(Mask, 1) << bit;
}

// =============================================================
// Arch-specific code
// =============================================================

/// Register context saved onto the user stack when a signal is delivered.
pub const SigFrame = switch (builtin.cpu.arch) {
    .aarch64 => extern struct {
        /// General-purpose registers x0–x30.
        regs: [31]u64,
        /// User SP.
        sp: u64,
        /// User PC at signal entry.
        pc: u64,
        /// PSTATE.
        pstate: u64,
        /// Signal mask to restore on sigreturn.
        saved_mask: Mask,
        /// Signal number that caused this frame.
        signo: SigInt,
    },

    else => @compileError("Unsupported architecture."),
};

/// Check if signals can be delivered in the current context.
fn isDeliverable(_: SigInt, ctx: *const Context) bool {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            return ctx.sp_el0 != 0; // only deliver when returning to EL0
        },

        else => @compileError("Unsupported architecture."),
    }
}

// =============================================================
// Internals
// =============================================================

/// Setup sigframe and modify the user context to execute the signal handler.
fn setupSigFrame(ctx: *Context, th: *Thread, signo: SigInt, action: Action) !void {
    const trampoline = if (th.sigstate.trampoline) |addr|
        addr
    else
        try allocateTrampoline(th);

    switch (builtin.cpu.arch) {
        .aarch64 => {
            const frame: *SigFrame = @ptrFromInt((ctx.sp_el0 - @sizeOf(SigFrame)));
            const regs: *const [31]u64 = @ptrCast(ctx);

            // Save user context into the sigframe.
            frame.* = .{
                .regs = regs.*,
                .sp = ctx.sp_el0,
                .pc = ctx.pc,
                .pstate = ctx.pstate,
                .saved_mask = th.sigstate.blocked,
                .signo = signo,
            };

            // Modify user context to execute the signal handler.
            ctx.x0 = signo;
            ctx.pc = action.handler;
            ctx.sp_el0 = @intFromPtr(frame);
            ctx.x30 = trampoline;
        },

        else => @compileError("Unsupported architecture."),
    }
}

/// Allocate a per-thread trampoline page.
fn allocateTrampoline(th: *Thread) !usize {
    // Map as user-RWX kernel-RWX.
    const uva = try th.vmm.mapAnon(mem.page_size, .{
        .ur = true,
        .uw = true,
        .ux = true,
        .kr = true,
        .kw = true,
        .kx = true,
    });

    // Place the trampoline code.
    const tramp = generateTrampoline();
    const src: [*]const u8 = @ptrFromInt(@intFromPtr(tramp.code));
    const dest: [*]u8 = @ptrFromInt(uva);
    @memcpy(dest[0..tramp.size], src[0..tramp.size]);

    // Remap as user-RX kernel-RX.
    try th.vmm.remap(uva, mem.page_size, .{
        .ur = true,
        .uw = false,
        .ux = true,
        .kr = true,
        .kw = false,
        .kx = true,
    });

    th.sigstate.trampoline = uva;
    return uva;
}

const Trampoline = struct {
    /// Trampoline code.
    code: *const fn () callconv(.naked) noreturn,
    /// Size in bytes of the trampoline code.
    size: usize,
};

/// Generate architecture-specific trampoline code for signal handlers.
fn generateTrampoline() Trampoline {
    return switch (builtin.cpu.arch) {
        .aarch64 => .{
            .size = 8,
            .code = struct {
                fn f() callconv(.naked) noreturn {
                    asm volatile (
                        \\movz x8, #139 // rt_sigreturn
                        \\svc  #0
                    );
                }
            }.f,
        },

        else => @compileError("Unsupported architecture."),
    };
}

// =============================================================
// Default handlers
// =============================================================

/// Get a default handler for the given signal number.
fn getDefaultHandler(signo: Signal) *const fn () void {
    return switch (signo) {
        else => defaultAbort,
    };
}

/// Default signal handler to abort.
fn defaultAbort() void {
    task.exit(-1);
}

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.signal);
const common = @import("common");
const arch = @import("arch").impl;
const Context = arch.exception.Context;
const urd = @import("urthr");
const mem = urd.mem;
const sched = urd.sched;
const task = urd.task;
const Thread = task.thread.Thread;
