/// Logger function type
pub const LogFn = *const fn (comptime format: []const u8, args: anytype) void;

/// Log level.
///
/// Can be configured by compile-time options. See build.zig.
pub const log_level = switch (options.log_level) {
    .debug => .debug,
    .info => .info,
    .warn => .warn,
    .err => .err,
};

const writer_vtable = std.Io.Writer.VTable{
    .drain = drain,
};

/// I/O writer instance.
var writer = std.Io.Writer{
    .vtable = &writer_vtable,
    .buffer = &.{},
};

/// Write data to the console subsystem.
fn drain(_: *std.Io.Writer, data: []const []const u8, _: usize) !usize {
    var written: usize = 0;
    for (data) |bytes| {
        console.write(bytes);
        written += bytes.len;
    }

    return written;
}

/// Log implementation.
pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    anyLog(switch (level) {
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERROR",
    }, scope, fmt, args);
}

pub fn anyLog(
    comptime level: []const u8,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (level.len > 5) {
        @compileError("Log level name too long: " ++ level);
    }
    const level_str = std.fmt.comptimePrint("[{s: <5}]", .{level});

    const scope_str = if (@tagName(scope).len <= 8) b: {
        break :b std.fmt.comptimePrint(
            "{s: <8}| ",
            .{@tagName(scope)},
        );
    } else b: {
        break :b std.fmt.comptimePrint(
            "{s: <7}-| ",
            .{@tagName(scope)[0..7]},
        );
    };

    writer.print(
        level_str ++ " " ++ scope_str ++ fmt ++ "\r\n",
        args,
    ) catch {};
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const io = std.io;
const options = @import("options");
const console = @import("console.zig");
