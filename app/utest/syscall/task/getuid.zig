test "never fails" {
    _ = linux.getuid();
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const linux = std.os.linux;
