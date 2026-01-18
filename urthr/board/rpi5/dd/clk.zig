//! The reference clock is a 50MHz crystal input.
//!
//! There're 3 internal PLLs: CORE, AUDIO, and VIDEO.

// =============================================================
// Module Definition
// =============================================================

/// Clock register set for a specific clock.
const Clock = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, Control },
});

/// Mapping of clock IDs to register set offsets.
const map = Map.new(&.{
    .{ .sys, 0x14 },
    .{ .eth, 0x64 },
});

/// Base address of the clock module.
var base: usize = undefined;

/// Get the register set of the given clock ID.
fn getModule(comptime id: Id) Clock {
    inline for (map) |m| {
        if (m.id == id) {
            var module = Clock{};
            module.setBase(base + m.offset);

            return module;
        }
    } else @compileError("Invalid clock ID.");
}

/// Clock IDs.
const Id = enum(u32) {
    sys = 12,
    slow_sys = 13,
    dma = 14,
    uart = 15,
    eth = 16,
    pwm0 = 17,
    pwm1 = 18,
};

const Map = struct {
    /// Clock ID.
    id: Id,
    /// Register set offset.
    offset: usize,

    pub fn new(comptime fields: []const struct { Id, usize }) [fields.len]Map {
        comptime var arr: [fields.len]Map = undefined;
        for (fields, 0..) |field, i| {
            arr[i] = Map{
                .id = field[0],
                .offset = field[1],
            };
        }
        return arr;
    }
};

// =============================================================
// API
// =============================================================

/// Set the base address of the clock module.
pub fn setBase(base_addr: usize) void {
    base = base_addr;
}

/// Initialize clocks.
pub fn init() void {}

// =============================================================
// I/O Registers
// =============================================================

const Control = packed struct(u32) {
    src: u5,
    auxsrc: u5,
    _0: u1 = 0,
    enable: bool,
    _1: u20 = 0,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.rp5clk);
const arch = @import("arch").impl;
const common = @import("common");
const mmio = common.mmio;
