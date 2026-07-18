pub const exception = @import("exception.zig");
pub const mmu = @import("mmu.zig");
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
    @panic("unimplemented");
}

/// Set the value that is unique to each core.
pub fn setPerCpuBase(_: usize) void {
    @panic("unimplemented");
}

/// Set system call handler function.
pub fn setSystemCallHandler(_: anytype) void {
    @panic("unimplemented");
}

/// Set hook called before every return to EL0.
pub fn setEreturnHook(_: anytype) void {
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
    /// Mask all exceptions.
    pub fn maskAll() u64 {
        @panic("unimplemented");
    }

    /// Set exception mask.
    pub fn setMask(_: u64) void {
        @panic("unimplemented");
    }

    /// Set the exception handler function.
    pub fn setHandler(_: anytype) void {
        @panic("unimplemented");
    }
};
