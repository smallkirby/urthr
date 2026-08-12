test "never fails" {
    _ = linux.getgid();
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const linux = std.os.linux;
