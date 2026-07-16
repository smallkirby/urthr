test "geteuid never fails" {
    _ = linux.geteuid();
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const linux = std.os.linux;
