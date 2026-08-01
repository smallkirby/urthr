pub const cpuid = @import("cpuid.zig");
pub const exception = @import("exception.zig");
pub const gdt = @import("gdt.zig");
pub const mmu = @import("mmu.zig");
pub const lapic = @import("lapic.zig");
pub const ioapic = @import("ioapic.zig");
pub const msi = @import("msi.zig");
pub const pic = @import("pic.zig");
pub const rng = @import("rng.zig");
pub const smp = @import("smp.zig");
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
pub const BarrierDomain = enum {
    /// Full system.
    full,
};

/// Memory barrier type.
pub const BarrierType = enum {
    // Release
    release,
    // Acquire
    acquire,
};

/// Issue a memory barrier.
pub fn barrier(_: BarrierDomain, typ: BarrierType) void {
    switch (typ) {
        .release => asm volatile ("sfence" ::: .{ .memory = true }),
        .acquire => asm volatile ("lfence" ::: .{ .memory = true }),
    }
}

/// Get the Unique ID of the current core.
pub fn getCoreId() usize {
    return lapic.getId();
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

/// Enable syscall architectural features.
pub fn initSyscall() void {
    svc.init();
}

/// Set system call handler function.
pub fn setSystemCallHandler(f: anytype) void {
    svc.setHandler(f);
}

/// Set hook called before every return to EL0.
pub fn setEreturnHook(f: anytype) void {
    exception.setEreturnHook(f);
}

/// Set page fault handler function.
pub fn setPageFaultHandler(f: exception.PageFaultHandler) void {
    exception.setPageFaultHandler(f);
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

    /// Unmask all maskable interrupts.
    pub fn unmaskAll() void {
        am.sti();
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

const svc = @import("svc.zig");
const am = @import("asm.zig");
