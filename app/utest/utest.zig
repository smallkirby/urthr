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

/// Check if the network is supported in the current environment.
pub fn skipIfNetUnsupported() !void {
    return if (options.net_supported) {} else error.SkipZigTest;
}

/// The path of this binary.
pub const myname = "/boot/bin/utest";

// Modules.
pub const fs = @import("fs.zig");
pub const mem = @import("mem.zig");
pub const net = @import("net.zig");
pub const signal = @import("signal.zig");
pub const time = @import("time.zig");

// =============================================================
// Test References
// =============================================================

test "hello" {
    std.log.info("Hello, Urthr Unit Test Framework!", .{});
}

comptime {
    _ = @import("devfs.zig");
    _ = @import("fs.zig");
    _ = @import("mem.zig");
    _ = @import("net.zig");
    _ = @import("sched.zig");
    _ = @import("signal.zig");
    _ = @import("system.zig");
    _ = @import("task.zig");
    _ = @import("time.zig");
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const options = @import("options");
