test "syscall: read" {
    const init = utest.getInit();

    const file = try std.Io.Dir.openFileAbsolute(
        init.io,
        utest.myname,
        .{},
    );
    defer file.close(init.io);

    var buf: [4]u8 = undefined;
    const ret = linux.read(file.handle, &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqualSlices(u8, std.elf.MAGIC, &buf);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const Test = utest.fs.Test;
