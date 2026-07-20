//! Writer that prints to a console without taking a lock.
//!
//! Intended for use in exception/panic handlers, where taking a lock could deadlock.

const Self = @This();

writer: std.Io.Writer = .{
    .vtable = &vtable,
    .buffer = &.{},
},
console: Console,

const vtable = std.Io.Writer.VTable{
    .drain = drain,
};

fn drain(w: *std.Io.Writer, data: []const []const u8, _: usize) !usize {
    const self: *Self = @fieldParentPtr("writer", w);
    var written: usize = 0;
    for (data) |bytes| {
        written += self.console.print(bytes);
    }
    return written;
}

pub fn init(console: Console) Self {
    return .{ .console = console };
}

pub fn log(self: *Self, comptime fmt: []const u8, args: anytype) void {
    self.writer.print(fmt ++ "\n", args) catch {};
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Console = @import("Console.zig");
