//! CPU random number generation support.

/// Check if the CPU supports an random number generation.
pub fn isSupported() bool {
    const ecx = cpuid.Leaf.version_info.query(null).ecx;
    return (ecx & (1 << 30)) != 0;
}

/// Get a hardware generated random value.
pub fn getRandom() ?u64 {
    return am.rdrand();
}

// =============================================================
// Imports
// =============================================================

const am = @import("asm.zig");
const cpuid = @import("cpuid.zig");
