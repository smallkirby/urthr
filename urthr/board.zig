//! Board-specific implementations.
//!
//! Boards know about the layout of devices and their addresses.
//! It operates the devices using dd module.

/// Supported board types.
pub const BoardType = enum {
    /// Raspberry Pi 4B
    rpi4b,
    /// Raspberry Pi 5
    rpi5,

    /// Get the board type from its name.
    pub fn from(name: []const u8) ?BoardType {
        for (std.enums.values(BoardType)) |bt| {
            if (std.mem.eql(u8, name, @tagName(bt))) {
                return bt;
            }
        }
        return null;
    }

    /// Get the binary name for this board.
    ///
    /// The binary is loaded by the firmware at boot time.
    pub fn outname(self: BoardType) []const u8 {
        return switch (self) {
            .rpi4b => "kernel8.img",
            .rpi5 => "kernel_2712.img",
        };
    }
};

/// Set of board-specific implementations.
pub const impl = switch (common.options.board) {
    .rpi4b => @import("board/rpi4b/board.zig"),
    .rpi5 => @import("board/rpi5/board.zig"),
};

/// Get the name of the board.
pub fn description() []const u8 {
    return switch (common.options.board) {
        .rpi4b => "Raspberry Pi 4B",
        .rpi5 => "Raspberry Pi 5",
    };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
