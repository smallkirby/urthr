//! Virtual memory map.
//!
//! This file is referenced by mkconst tool.

pub const user = Range{
    .start = 0x0000_0000_0000_0000,
    .end = 0x0001_0000_0000_0000,
};

pub const linear = Range{
    .start = 0xFFFF_0000_0000_0000,
    .end = 0xFFFF_C000_0000_0000,
};

pub const device = Range{
    .start = 0xFFFF_C000_0000_0000,
    .end = 0xFFFF_E000_0000_0000,
};

pub const vmem = Range{
    .start = 0xFFFF_E000_0000_0000,
    .end = 0xFFFF_F000_0000_0000,
};

pub const kernel = Range{
    .start = 0xFFFF_FF00_0000_0000,
    .end = 0xFFFF_FFF0_0000_0000,
};

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const Range = common.Range;
