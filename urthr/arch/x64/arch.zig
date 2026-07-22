pub const cpuid = @import("cpuid.zig");
pub const exception = @import("exception.zig");
pub const gdt = @import("gdt.zig");
pub const mmu = @import("mmu.zig");
pub const lapic = @import("lapic.zig");
pub const ioapic = @import("ioapic.zig");
pub const pic = @import("pic.zig");
pub const rng = @import("rng.zig");
pub const timer = @import("timer.zig");
pub const thread = @import("thread.zig");

pub const StackIterator = @import("StackIterator.zig");

/// Execute a single NOP instruction.
pub fn nop() void {
    asm volatile ("nop");
}

/// Halt the CPU until the next interrupt.
pub fn halt() void {
    asm volatile ("hlt");
}

/// Memory barrier domain.
pub const BarrierDomain = enum {};

/// Memory barrier type.
pub const BarrierType = enum {
    // Release
    release,
    // Acquire
    acquire,
};

/// Issue a memory barrier.
pub fn barrier(_: BarrierDomain, _: BarrierType) void {
    @panic("unimplemented");
}

/// Get the Unique ID of the current core.
pub fn getCoreId() usize {
    @panic("unimplemented");
}

/// Get the value that is unique to each core.
pub fn getPerCpuBase() usize {
    return asm volatile (
        \\rdgsbase %[addr]
        : [addr] "=r" (-> usize),
        :
        : .{ .memory = true });
}

/// Set the value that is unique to each core.
pub fn setPerCpuBase(addr: usize) void {
    asm volatile (
        \\wrgsbase %[addr]
        :
        : [addr] "r" (addr),
        : .{ .memory = true });
}

/// Set system call handler function.
pub fn setSystemCallHandler(_: anytype) void {
    @panic("unimplemented");
}

/// Set hook called before every return to EL0.
pub fn setEreturnHook(_: anytype) void {
    @panic("unimplemented");
}

/// Set page fault handler function.
pub fn setPageFaultHandler(_: anytype) void {
    @panic("unimplemented");
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

pub const intr = struct {
    /// Mask all maskable interrupts.
    ///
    /// Returns the previous RFLAGS so it can be restored later.
    pub fn maskAll() u64 {
        return asm volatile (
            \\pushfq
            \\cli
            \\popq %[flags]
            : [flags] "=r" (-> u64),
            :
            : .{ .memory = true });
    }

    /// Set exception mask.
    pub fn setMask(flags: u64) void {
        asm volatile (
            \\pushq %[flags]
            \\popfq
            :
            : [flags] "r" (flags),
            : .{ .memory = true, .cc = true });
    }

    /// Set the exception handler function.
    pub fn setHandler(handler: exception.Handler) void {
        exception.setHandler(handler);
    }
};

// =============================================================
// Imports
// =============================================================

// Force evaluate symbols exported but not referenced in Zig.
comptime {
    _ = @import("head.zig");
}
