const Context = extern struct {
    x29: usize,
    x30: usize,
    x27: usize,
    x28: usize,
    x25: usize,
    x26: usize,
    x23: usize,
    x24: usize,
    x21: usize,
    x22: usize,
    x19: usize,
    x20: usize,
};

/// Initialize the thread stack.
pub fn initStack(stack: []u8, entry: anytype, arg: anytype) []u8 {
    const context: *align(16) Context = @ptrCast(@alignCast(stack[stack.len - @sizeOf(Context) ..].ptr));

    context.* = .{
        .x19 = @intFromPtr(entry),
        .x20 = @intFromPtr(arg),
        .x21 = 0,
        .x22 = 0,
        .x23 = 0,
        .x24 = 0,
        .x25 = 0,
        .x26 = 0,
        .x27 = 0,
        .x28 = 0,
        .x29 = 0,
        .x30 = @intFromPtr(&trampoline),
    };

    return stack[0 .. stack.len - @sizeOf(Context)];
}

/// Switch context from the old thread to the new thread.
pub extern fn switchContext(old: *usize, new: *const usize) callconv(.c) void;

/// Thread entry trampoline function.
fn trampoline() callconv(.naked) noreturn {
    asm volatile (
        \\
        // Call the thread function with the provided argument.
        \\mov x0, x20
        \\blr x19
        // Unreachable.
        \\udf #0
    );
}
