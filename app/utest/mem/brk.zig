test "brk with addr=0 returns the current program break" {
    const cur1 = linux.brk(0);
    const cur2 = linux.brk(0);
    try testing.expectEqual(cur1, cur2);
    try testing.expectEqual(.SUCCESS, linux.errno(cur1));
}

test "brk can extend the program break by one page" {
    const page_size = std.heap.pageSize();
    const cur = linux.brk(0);
    try testing.expectEqual(.SUCCESS, linux.errno(cur));

    const requested = cur + page_size;
    const new = linux.brk(requested);
    try testing.expectEqual(.SUCCESS, linux.errno(new));
    try testing.expectEqual(requested, new);

    // Restore the original break.
    _ = linux.brk(cur);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
