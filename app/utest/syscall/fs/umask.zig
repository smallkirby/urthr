test "syscall: umask sets the mask and returns the previous value" {
    const orig = getUmask();
    defer _ = umask(orig);

    try testing.expectEqual(orig, umask(0o077));
    try testing.expectEqual(@as(usize, 0o077), umask(0o022));
}

test "umask only honors the low 9-bits" {
    const orig = getUmask();
    defer _ = umask(orig);

    _ = umask((~@as(usize, 0) << 9) | 0o022);
    try testing.expectEqual(@as(usize, 0o022), getUmask());
}

// =============================================================
// Helpers
// =============================================================

/// Install `mask` and return the mask that was in effect before the call.
fn umask(mask: usize) usize {
    return linux.syscall1(.umask, mask);
}

/// Query the current mask without leaving it modified.
fn getUmask() usize {
    const cur = umask(0o022);
    _ = umask(cur);
    return cur;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
