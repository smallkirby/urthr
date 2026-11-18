//! CPU architecture abstractions.

// Set of architecture-specific implementations.
pub const impl = switch (builtin.target.cpu.arch) {
    .aarch64 => @import("arch/aarch64/arch.zig"),
    .x86_64 => @import("arch/x64/arch.zig"),
    .riscv64 => @import("arch/riscv64/arch.zig"),
    else => @compileError("Unsupported architecture."),
};

/// Function signature of exception handler.
///
/// Returns null if the exception cannot be handled.
pub const ExceptionHandler = *const fn (u64) ?void;

/// State of the thread interrupted by an IRQ.
pub const InterruptedInfo = struct {
    /// Instruction pointer.
    pc: u64,
    /// Frame pointer. Valid only when `user` is false.
    fp: u64,
    /// Code was running in user mode when interrupted.
    user: bool,
};

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");

// Force evaluate symbols exported but not referenced in Zig.
comptime {
    _ = impl;
}
