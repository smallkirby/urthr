//! Urthr Userland Unit Test Framework.
//!
//! All tests are run in the same process.
//! So tests should clean up after themselves, and not depend on other tests.
//!
//! Tests named "tag:ONLY" will be run exclusively, and all other tests will be skipped.

/// Pointer to the juicy-init instance, bridged from the test runner.
export var utest_init_ptr: ?*std.process.Init = null;

/// Get juicy-init instance.
pub fn getInit() std.process.Init {
    return utest_init_ptr.?.*;
}

/// The path of this binary.
pub const myname = "/boot/bin/utest";

// =============================================================
// Test References
// =============================================================

test "hello" {
    std.log.info("Hello, Urthr Unit Test Framework!", .{});
}

comptime {
    _ = @import("devfs.zig");
    _ = @import("fs.zig");
    _ = @import("signal.zig");
    _ = @import("time.zig");
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
