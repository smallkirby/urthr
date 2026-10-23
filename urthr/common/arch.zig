//! Architecture-independent types shared by all arch implementations.

/// State of the thread interrupted by an IRQ.
pub const InterruptedInfo = struct {
    /// Instruction pointer.
    pc: u64,
    /// Frame pointer. Valid only when `user` is false.
    fp: u64,
    /// Code was running in user mode when interrupted.
    user: bool,
};
