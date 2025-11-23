//! Common library code that can be used in every module.

pub const mmio = @import("common/mmio.zig");
pub const util = @import("common/util.zig");

pub const Console = @import("common/Console.zig");

pub const options = @import("options");

// =============================================================
// Tests
// =============================================================

test {
    _ = mmio;
    _ = util;
}
