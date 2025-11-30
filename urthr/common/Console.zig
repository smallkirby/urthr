//! Console interface.

const Self = @This();

vtable: Vtable,
ctx: *anyopaque,

pub const Vtable = struct {
    /// Print a single character to the console.
    putc: *const fn (ctx: *anyopaque, c: u8) void,
    /// Ensure that all previous output has been transmitted.
    flush: *const fn (ctx: *anyopaque) void,
};

/// Print a string to the console.
pub fn print(self: *Self, s: []const u8) usize {
    for (s) |b| {
        self.vtable.putc(self.ctx, b);
    }

    return s.len;
}

/// Print a string followed by a newline to the console.
pub fn println(self: *Self, s: []const u8) usize {
    const n = self.print(s);
    self.vtable.putc(self.ctx, '\n');
    return n + 1;
}
