test "syscall: fchmodat" {
    const ret = linux.fchmodat(linux.AT.FDCWD, utest.myname, 0o644);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

test "fchmodat on a non-existent file fails with ENOENT" {
    const ret = linux.fchmodat(
        linux.AT.FDCWD,
        Test.base_dir ++ "/no-such-file",
        0o644,
    );
    try testing.expectEqual(.NOENT, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const Test = utest.fs.Test;
