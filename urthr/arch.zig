//! CPU architecture abstractions.

// Set of architecture-specific implementations.
pub const impl = switch (builtin.target.cpu.arch) {
    .aarch64 => @import("arch/aarch64/arch.zig"),
    .x86_64 => @import("arch/x64/arch.zig"),
    .riscv64 => @import("arch/riscv64/arch.zig"),
    else => @compileError("Unsupported architecture."),
};

// =============================================================
// Interrupts

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
// MMU

pub const MmuError = error{
    /// Current mapping does not match the requested mapping.
    InvalidMapping,
} || PageAllocator.Error;

pub const MapArgument = struct {
    /// Virtual address to map.
    va: usize,
    /// Physical address to map.
    pa: usize,
    /// Size in bytes to map.
    size: usize,
    /// Permission of the mapping.
    perm: Permission,
    /// Attribute of the mapping.
    attr: Attribute,
};

pub const MapOptions = struct {
    /// Returns an error if the given addresses are not aligned to the given granule size.
    exact: bool = true,
    /// Whether to flush the TLB after the operation completes.
    flush: bool = true,
};

pub const RemapOptions = struct {
    /// Whether to flush the TLB after the operation completes.
    flush: bool = true,
};

pub const UnmapOptions = struct {
    /// Whether to flush the TLB after the operation completes.
    flush: bool = true,
};

/// Translation level.
///
/// This counts the number of table descents from the top-level table.
/// 5-level translation is not supported.
pub const Level = u2;

/// Size of page block.
pub const Granule = enum {
    @"4kb",
    @"2mb",
    @"1gb",

    /// Size in bytes.
    pub fn granule(self: Granule) usize {
        return switch (self) {
            .@"4kb" => 4 * units.kib,
            .@"2mb" => 2 * units.mib,
            .@"1gb" => 1 * units.gib,
        };
    }

    /// Translation level of the leaf entry.
    pub fn level(self: Granule) Level {
        return switch (self) {
            .@"4kb" => 3,
            .@"2mb" => 2,
            .@"1gb" => 1,
        };
    }
};

/// Scope of TLB invalidation.
pub const TlbScope = enum {
    /// Local to this core.
    local,
    /// All CPUs.
    global,
};

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const common = @import("common");
const units = common.units;
const Attribute = common.mem.Attribute;
const Permission = common.mem.Permission;
const PageAllocator = common.mem.PageAllocator;

// Force evaluate symbols exported but not referenced in Zig.
comptime {
    _ = impl;
}
