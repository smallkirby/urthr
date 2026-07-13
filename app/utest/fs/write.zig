test "syscall: write" {
    const init = utest.getInit();

    const file = try std.Io.Dir.openFileAbsolute(
        init.io,
        utest.myname,
        .{},
    );
    defer file.close(init.io);

    const content = "urthr";
    const ret = linux.write(file.handle, content, content.len);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@as(usize, content.len), ret);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const Test = utest.fs.Test;
