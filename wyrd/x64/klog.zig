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

/// Pointer to SimpleTextOutput protocol instance.
var sto: *SimpleTextOutput = undefined;

/// Write data to the serial console.
fn drain(_: *std.Io.Writer, data: []const []const u8, _: usize) !usize {
    var written: usize = 0;
    for (data) |bytes| {
        for (bytes) |b| {
            var buf: [2]u16 = undefined;
            buf[0] = @intCast(b);
            buf[1] = 0;
            _ = sto.outputString(@ptrCast(buf[0..1])) catch unreachable;
        }
        written += bytes.len;
    }

    return written;
}

/// Initialize the console used for logging.
pub fn init(c: *SimpleTextOutput) void {
    sto = c;
}

/// Log implementation.
pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const level_str = comptime switch (level) {
        .debug => "[DEBUG]",
        .info => "[INFO ]",
        .warn => "[WARN ]",
        .err => "[ERROR]",
    };

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
const uefi = std.os.uefi;
const SimpleTextOutput = uefi.protocol.SimpleTextOutput;
const options = @import("options");
