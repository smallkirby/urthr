test "never fails" {
    _ = linux.getegid();
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const linux = std.os.linux;
