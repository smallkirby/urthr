/// SVC handler function type.
const HandlerFn = fn (
    nr: u64,
    arg1: u64,
    arg2: u64,
    arg3: u64,
    arg4: u64,
    arg5: u64,
    arg6: u64,
) i64;

/// SVC dispatcher.
var dispatcher: *const HandlerFn = undefined;

/// Set SVC handler function.
pub fn setHandler(f: *const HandlerFn) void {
    dispatcher = f;
}

/// SVC handler.
pub fn svc(ctx: *Context) void {
    const nr = ctx.x8;
    const arg1 = ctx.x0;
    const arg2 = ctx.x1;
    const arg3 = ctx.x2;
    const arg4 = ctx.x3;
    const arg5 = ctx.x4;
    const arg6 = ctx.x5;

    // Save and restore user stack pointer.
    const sp_el0 = am.mrsi(.sp_el0);
    defer am.msr(.sp_el0, @bitCast(sp_el0));

    // Save and restore user thread pointer.
    const tpidr_el0 = am.mrsi(.tpidr_el0);
    defer am.msr(.tpidr_el0, @bitCast(tpidr_el0));

    // Dispatch system call.
    const ret = dispatcher(
        nr,
        arg1,
        arg2,
        arg3,
        arg4,
        arg5,
        arg6,
    );
    ctx.x0 = @bitCast(ret);
}

// =============================================================
// Imports
// =============================================================

const am = @import("asm.zig");
const Context = @import("isr.zig").Context;
