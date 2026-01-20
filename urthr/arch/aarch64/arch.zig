pub const exception = @import("isr.zig");
pub const mmu = @import("mmu.zig");
pub const timer = @import("timer.zig");

/// Execute a single NOP instruction.
pub fn nop() void {
    asm volatile ("nop");
}

/// Halt the CPU until the next interrupt.
pub fn halt() void {
    asm volatile ("wfi");
}

/// Memory barrier domain.
pub const BarrierDomain = enum {
    /// Full system.
    full,
    /// Inner shareable.
    inner,
};

/// Memory barrier type.
pub const BarrierType = enum {
    // Release
    release,
    // Acquire
    acquire,
};

/// Issue a memory barrier.
pub fn barrier(domain: BarrierDomain, typ: BarrierType) void {
    switch (domain) {
        .full => asm volatile ("dmb sy"),
        .inner => switch (typ) {
            .release => asm volatile ("dmb ishst"),
            .acquire => asm volatile ("dmb ishld"),
        },
    }
}
/// Write back data cache range described by the given virtual address.
///
/// This function ensures that any modified data in the specified range is written back to main memory.
/// Those data still remain in the cache in CPU view.
///
/// TODO: calculate cache line size on startup and use it here.
pub fn cleanDcacheRange(addr: usize, size: usize) void {
    var current = addr & ~@as(usize, 0x3F);
    const end = addr + size;
    while (current < end) : (current += 64) {
        asm volatile ("dc cvac, %[addr]"
            :
            : [addr] "r" (current),
            : .{ .memory = true });
    }

    asm volatile ("dsb sy");
}

/// Translate the given virtual address to physical address.
pub fn translate(virt: usize) usize {
    // TODO: should check the fault status
    // TODO: should strip the bottom bits
    return asm volatile (
        \\at S1E1R, %[virt]
        \\isb
        \\mrs %[out], PAR_EL1
        : [out] "=r" (-> u64),
        : [virt] "r" (virt),
        : .{ .memory = true });
}

/// Exception APIs.
pub const intr = struct {
    /// Mask all exceptions.
    pub fn maskAll() u64 {
        const daif = am.mrs(.daif);
        am.msr(.daif, .{
            .d = daif.d,
            .a = daif.a,
            .i = true,
            .f = true,
        });
        am.isb();

        return @bitCast(daif);
    }

    /// Set exception mask.
    pub fn setMask(daif: u64) void {
        am.msr(.daif, @bitCast(daif));
    }
};

// =============================================================
// Imports
// =============================================================

// Force evaluate symbols exported but not referenced in Zig.
comptime {
    _ = exception;
}

const am = @import("asm.zig");
