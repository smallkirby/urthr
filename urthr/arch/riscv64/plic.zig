//! RISC-V Platform-Level Interrupt Controller (PLIC) driver.
//!
//! ref. RISC-V Platform-Level Interrupt Controller Specification Version 1.0.0, 3/2023

// =============================================================
// Module Definition
// =============================================================

var plic = mmio.Module(.{ .size = u32 }, .{
    Arr(0x00_0000, Priority, max_sources, 4),
    Sub(0x00_2000, Enable, max_contexts, 0x80),
    Sub(0x20_0000, Context, max_contexts, 0x1000),
}){};

/// Interrupt enable bits of a context.
///
/// Up to 1024 interrupt sources can be enabled per context.
const Enable = mmio.Module(.{ .size = u32 }, .{
    Arr(0x0, EnableBits, max_sources / @bitSizeOf(EnableBits), @sizeOf(EnableBits)),
});

/// Maximum number of the interrupt sources defined by the specification.
const max_sources = 1024;
/// Maximum number of the contexts defined by the specification.
const max_contexts = 15872;

/// Registers of a context.
///
/// Context means a pair of a hart and a privilege level.
const Context = mmio.Module(.{ .size = u32 }, .{
    Reg(0x0, Threshold),
    Reg(0x4, ClaimComplete),
});

// =============================================================

/// Set the base address of the PLIC registers.
pub fn setBase(base: usize) void {
    plic.setBase(base);
}

/// Enable the given interrupt source for the given context.
pub fn enable(context: usize, source: u32) void {
    const enables = plic.sub(Enable, context);
    const index = source / @bitSizeOf(EnableBits);

    var bits = enables.readIndexed(EnableBits, index);
    bits.bits |= @as(u32, 1) << @intCast(source % @bitSizeOf(EnableBits));
    enables.writeIndexed(EnableBits, index, bits);
}

/// Disable the given interrupt source for the given context.
pub fn disable(context: usize, source: u32) void {
    const mod = plic.sub(Enable, context);
    const index = source / @bitSizeOf(EnableBits);

    var bits = mod.readIndexed(EnableBits, index);
    bits.bits &= ~(@as(u32, 1) << @intCast(source % @bitSizeOf(EnableBits)));
    mod.writeIndexed(EnableBits, index, bits);
}

/// Set the priority of the given interrupt source.
///
/// Priority 0 means the interrupt is disabled.
/// Interrupt priority increases with increasing integer values.
pub fn setPriority(source: u32, priority: u32) void {
    plic.writeIndexed(Priority, source, Priority{
        .priority = priority,
    });
}

/// Set the priority threshold of the given context.
///
/// Interrupts whose priority is not greater than the threshold are masked.
pub fn setThreshold(context: usize, threshold: u32) void {
    plic.sub(Context, context).write(Threshold, .{
        .priority = threshold,
    });
}

/// Claim the highest-priority pending interrupt of the given context.
///
/// Returns zero if there is no pending interrupt.
pub fn claim(context: usize) u32 {
    return plic.sub(Context, context).read(ClaimComplete).source;
}

/// Signal the completion of the given interrupt source.
pub fn complete(context: usize, source: u32) void {
    plic.sub(Context, context).write(ClaimComplete, .{
        .source = source,
    });
}

// =============================================================
// Registers
// =============================================================

/// Priority of an interrupt source.
const Priority = packed struct(u32) {
    /// Priority.
    priority: u32,
};

/// Interrupt enable bits for 32 interrupt sources.
const EnableBits = packed struct(u32) {
    /// Bits corresponding to the 32 interrupt sources.
    bits: u32,
};

/// Priority threshold of a context.
const Threshold = packed struct(u32) {
    /// Priority threshold.
    priority: u32,
};

/// Claim and complete of a context.
///
/// A read claims the highest-priority pending interrupt.
/// A write signals the completion of the given interrupt.
///
/// An interrupt ID of 0 is reserved to mean "no interrupt".
const ClaimComplete = packed struct(u32) {
    /// Interrupt source.
    source: u32,
};

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const mmio = common.io.mmio;
const Reg = common.io.Reg;
const Arr = common.io.Arr;
const Sub = common.io.Sub;
