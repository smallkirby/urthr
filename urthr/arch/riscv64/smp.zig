//! Handles subcore bringup sequence.

/// Called by a secondary core after it has been woken up.
pub fn localInit(_: usize) void {}

/// Get the virtual address that must be identity-mapped during secondary core boot.
pub fn getIdentityAddress() usize {
    @panic("TODO: SMP is not supported on riscv64 yet.");
}
