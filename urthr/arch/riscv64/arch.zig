pub const exception = @import("isr.zig");
pub const mmu = @import("mmu.zig");
pub const smp = @import("smp.zig");
pub const timer = @import("timer.zig");
pub const thread = @import("thread.zig");
pub const uaccess = @import("uaccess.zig");

pub const StackIterator = @import("StackIterator.zig");

const todo = "TODO: RISC-V: not supported yet";

/// Execute a single NOP instruction.
pub fn nop() void {
    asm volatile ("nop");
}

/// Halt the CPU until the next interrupt.
pub fn halt() void {
    asm volatile ("wfi");
}

/// Wait until an interrupt becomes pending.
pub fn wfi() void {
    @panic(todo);
}

/// Memory barrier domain.
pub const BarrierDomain = enum {};

/// Memory barrier type.
pub const BarrierType = enum {};

/// Issue a memory barrier.
pub fn barrier(_: BarrierDomain, _: BarrierType) void {
    @panic(todo);
}

/// Get the Unique ID of the current core.
pub fn getCoreId() usize {
    @panic(todo);
}

/// Get the value that is unique to each core.
pub fn getPerCpuBase() usize {
    return asm volatile (
        \\mv %[addr], tp
        : [addr] "=r" (-> usize),
        :
        : .{ .memory = true });
}

/// Set the value that is unique to each core.
pub fn setPerCpuBase(addr: usize) void {
    asm volatile (
        \\mv tp, %[addr]
        :
        : [addr] "r" (addr),
        : .{ .memory = true });
}

/// Enable syscall architectural features.
pub fn initSyscall() void {
    @panic(todo);
}

/// Set system call handler function.
pub fn setSystemCallHandler(_: anytype) void {
    @panic(todo);
}

/// Set hook called before every return to EL0.
pub fn setEreturnHook(_: exception.EreturnHook) void {
    @panic(todo);
}

/// Set page fault handler function.
pub fn setPageFaultHandler(_: exception.PageFaultHandler) void {
    @panic(todo);
}

/// Set user fault handler function.
pub fn setUserFaultHandler(_: exception.UserFaultHandler) void {
    @panic(todo);
}

/// Exception APIs.
pub const intr = struct {
    /// SIE bit of SSTATUS CSR.
    const sstatus_sie: u64 = 1 << 1;

    /// Mask all exceptions.
    ///
    /// Returns the previous state that can be restored later.
    pub fn maskAll() u64 {
        const old = asm volatile ("csrrc %[old], sstatus, %[mask]"
            : [old] "=r" (-> u64),
            : [mask] "r" (sstatus_sie),
            : .{ .memory = true });
        return old & sstatus_sie;
    }

    /// Get exception mask.
    pub fn getMask() u64 {
        const sstatus = asm volatile ("csrr %[sstatus], sstatus"
            : [sstatus] "=r" (-> u64),
            :
            : .{ .memory = true });
        return sstatus & sstatus_sie;
    }

    /// Set exception mask.
    pub fn setMask(mask: u64) void {
        if (mask & sstatus_sie != 0) {
            asm volatile ("csrs sstatus, %[mask]"
                :
                : [mask] "r" (sstatus_sie),
                : .{ .memory = true });
        } else {
            asm volatile ("csrc sstatus, %[mask]"
                :
                : [mask] "r" (sstatus_sie),
                : .{ .memory = true });
        }
    }

    /// Unmask all maskable interrupts.
    pub fn unmaskAll() void {
        asm volatile ("csrs sstatus, %[mask]"
            :
            : [mask] "r" (sstatus_sie),
            : .{ .memory = true });
    }

    /// Set the exception handler function.
    pub fn setHandler(handler: exception.Handler) void {
        exception.setHandler(handler);
    }
};
