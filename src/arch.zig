//! CPU architecture abstractions.

// Set of architecture-specific implementations.
pub const impl = switch (builtin.target.cpu.arch) {
    .aarch64 => @import("arch/aarch64/arch.zig"),
    else => @compileError("Unsupported architecture."),
};

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");

// Force evaluate symbols exported but not referenced in Zig.
comptime {
    _ = impl;
}
