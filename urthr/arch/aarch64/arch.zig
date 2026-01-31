pub const exception = @import("isr.zig");
pub const gicv2 = @import("gicv2.zig");
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
        .full => asm volatile ("dsb sy"),
        .inner => switch (typ) {
            .release => asm volatile ("dsb ishst"),
            .acquire => asm volatile ("dsb ishld"),
        },
    }
}

/// Cache operation type.
const CacheOp = enum {
    /// Invalidate cache lines.
    ///
    /// The data in the cache lines are discarded.
    invalidate,
    /// Clean cache lines.
    ///
    /// The data in the cache lines are written back to main memory.
    clean,
};

/// Size in bytes of cache line.
const cacheline_size = 64;
/// Mask for cache line alignment.
const cacheline_mask = cacheline_size - 1;

/// Do cache operation on the specified range.
pub fn cache(op: CacheOp, addr: anytype, size: usize) void {
    var current = util.anyaddr(addr) & ~@as(usize, cacheline_mask);
    const end = util.anyaddr(addr) + size;
    while (current < end) : (current += cacheline_size) {
        switch (op) {
            .invalidate => asm volatile ("dc ivac, %[addr]"
                :
                : [addr] "r" (current),
                : .{ .memory = true }),
            .clean => asm volatile ("dc cvac, %[addr]"
                :
                : [addr] "r" (current),
                : .{ .memory = true }),
        }
    }

    asm volatile ("dsb ish");
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

    /// Set the exception handler function.
    pub fn setHandler(handler: exception.HandlerSignature) void {
        exception.setHandler(handler);
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
const util = @import("common").util;
