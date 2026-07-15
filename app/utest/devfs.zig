test "/dev/zero" {
    const init = utest.getInit();

    const dzero = try std.Io.Dir.openFileAbsolute(
        init.io,
        "/dev/zero",
        .{ .mode = .read_write },
    );
    defer dzero.close(init.io);

    var buf: [16]u8 = undefined;
    var reader = dzero.reader(init.io, &.{});
    try reader.interface.readSliceAll(&buf);

    var writer = dzero.writer(init.io, &.{});
    try writer.interface.writeAll(&buf);
}

test "/dev/null" {
    const init = utest.getInit();

    const dnull = try std.Io.Dir.openFileAbsolute(
        init.io,
        "/dev/null",
        .{ .mode = .read_write },
    );
    defer dnull.close(init.io);

    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var reader = dnull.reader(init.io, &.{});
    if (try reader.interface.streamRemaining(&w) != 0) {
        return error.UnexpectedNullRead;
    }

    var writer = dnull.writer(init.io, &.{});
    try writer.interface.writeAll(&buf);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const utest = @import("utest.zig");
