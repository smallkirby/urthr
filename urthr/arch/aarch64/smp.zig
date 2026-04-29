//! Handles subcore bringup sequence.

/// Secondary cores use this data to set up their execution environment
const SmpBootData = extern struct {
    /// TTBR0.
    ttbr0: u64,
    /// TTBR1.
    ttbr1: u64,
    /// TCR.
    tcr: u64,
    /// MAIR.
    mair: u64,
    /// Virtual address of the kernel subcore entry point.
    entry: u64,
    /// Virtual address of the stack for the secondary core.
    stack: u64,
};

/// Boot data.
///
/// This variable is accessed by secondary cores during boot only without MMU disabled.
/// Writes from the primary core must be visible to secondary cores.
export var _boot_data: SmpBootData = undefined;

/// Whether the boot data has been initialized by the primary core.
///
/// Accessed only by the primary core.
var boot_data_initialized = false;

/// Subcore entry point.
///
/// This function is executed both with and without MMU enabled.
/// Thus, the address must be identity-mapped during secondary core boot.
extern fn _substart() callconv(.naked) void;

/// Function signature of the subcore secondary entry point.
///
/// This powered-on CPU core enables MMU, and jumps to this function.
pub const EntryFn = fn () callconv(.c) noreturn;

/// Board-specific function to clean entire data cache.
pub const Cleaner = fn () void;

/// Wakeup a secondary core by using a spintable.
pub fn wakeSpin(
    core: usize,
    spintable: usize,
    f: *const EntryFn,
    stack: usize,
    cleaner: *const Cleaner,
) void {
    // Check if the target core is not a primary core.
    rtt.expect(core != 0);

    // Check if the current core is a primary core.
    const mpidr = am.mrs(.mpidr_el1).aff0;
    rtt.expectEqual(0, mpidr);

    // Initialize boot data that is referenced by the secondary core during boot.
    if (!boot_data_initialized) {
        initBootData();
        boot_data_initialized = true;
    }
    _boot_data.entry = @intFromPtr(f);
    _boot_data.stack = stack;

    // Ensure the boot data is visible to the secondary core.
    cleaner();

    const entry: *volatile u64 = @ptrFromInt(spintable);
    entry.* = mmu.getPhysicalAddress(@intFromPtr(&_substart));
    asm volatile (
        \\dsb sy
        \\sev
    );
}

/// Wakeup a secondary core by using PSCI.
pub fn wakePsci(
    core: usize,
    f: usize,
    stack: usize,
    cleaner: *const Cleaner,
) void {
    // Check if PSCI is supported.
    const version = psci.getVersion() catch {
        @panic("Failed to get PSCI version.");
    };
    rtt.expect(version.major >= 1);

    // Check if the target core is not a primary core.
    rtt.expect(core != 0);

    // Check if the current core is a primary core.
    const mpidr = am.mrs(.mpidr_el1).aff0;
    rtt.expectEqual(0, mpidr);

    // Initialize boot data that is referenced by the secondary core during boot.
    if (!boot_data_initialized) {
        initBootData();
        boot_data_initialized = true;
    }
    _boot_data.entry = f;
    _boot_data.stack = stack;

    // Ensure the boot data is visible to the secondary core.
    cleaner();

    // Wakeup the core.
    const entry: usize = mmu.getPhysicalAddress(@intFromPtr(&_substart));
    psci.awakePe(core, entry, 0) catch {
        @panic("Failed to wake up core.");
    };
}

/// Get the virtual address that must be identity-mapped during secondary core boot.
pub fn getIdentityAddress() usize {
    return mmu.getPhysicalAddress(@intFromPtr(&_substart));
}

/// Initialize the boot data by copying the relevant register values of the current core.
fn initBootData() void {
    _boot_data.ttbr0 = asm volatile (
        \\mrs %[ttbr0], ttbr0_el1
        : [ttbr0] "=r" (-> u64),
    );
    _boot_data.ttbr1 = asm volatile (
        \\mrs %[ttbr1], ttbr1_el1
        : [ttbr1] "=r" (-> u64),
    );
    _boot_data.tcr = asm volatile (
        \\mrs %[tcr], tcr_el1
        : [tcr] "=r" (-> u64),
    );
    _boot_data.mair = asm volatile (
        \\mrs %[mair], mair_el1
        : [mair] "=r" (-> u64),
    );
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const rtt = common.rtt;
const am = @import("asm.zig");
const mmu = @import("mmu.zig");
const psci = @import("psci.zig");
