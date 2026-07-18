const IsrContext = void;

/// Initialize the thread stack.
pub fn initStack(_: []u8, _: anytype, _: anytype) []u8 {
    @panic("unimplemented");
}

/// Initialize the thread stack for a cloned child process.
pub fn initStackFork(_: []u8, _: *const IsrContext, _: usize) []u8 {
    @panic("unimplemented");
}

/// Get the current user stack pointer.
pub fn getUserStackPointer() usize {
    @panic("unimplemented");
}

/// Get the ISR context saved on the given kernel stack.
///
/// Valid only when called from a syscall handler.
pub fn isrContextOf(_: []u8) *IsrContext {
    @panic("unimplemented");
}

/// Switch context from the old thread to the new thread.
pub extern fn switchContext(old: *usize, new: *const usize) callconv(.c) void;

/// Set the thread pointer (TPIDR_EL0) for TLS.
pub fn setThreadPointer(_: usize) void {
    @panic("unimplemented");
}

/// Drop from EL1 to EL0 and start executing at the given user PC with the given user SP.
///
/// Does not return.
pub extern fn enterUserland(pc: usize, sp: usize, kstack: usize) callconv(.c) noreturn;

// =============================================================
// Imports
// =============================================================

const std = @import("std");
