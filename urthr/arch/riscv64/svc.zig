/// System call handler function type.
///
/// When null is returned, A0 is not modified and returned as-is to user.
const HandlerFn = fn (
    nr: u64,
    arg1: u64,
    arg2: u64,
    arg3: u64,
    arg4: u64,
    arg5: u64,
    arg6: u64,
) ?i64;

/// System call dispatcher.
var dispatcher: *const HandlerFn = undefined;

/// Set system call handler function.
pub fn setHandler(f: *const HandlerFn) void {
    dispatcher = f;
}

/// Handle ECALL from U-mode.
pub fn ecall(ctx: *Context) void {
    // Return to the instruction next to ECALL.
    ctx.sepc += 4;

    if (dispatcher(
        ctx.a7,
        ctx.a0,
        ctx.a1,
        ctx.a2,
        ctx.a3,
        ctx.a4,
        ctx.a5,
    )) |ret| {
        ctx.a0 = @bitCast(ret);
    }

    // Deliver any pending signals before returning to userspace.
    isr.callEreturnHook(ctx);
}

// =============================================================
// Imports
// =============================================================

const isr = @import("isr.zig");
const Context = isr.Context;
