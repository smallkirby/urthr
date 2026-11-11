const todo = "TODO: RISC-V: thread is not supported yet";

/// Layout of the saved FPU state.
pub const FpuState = extern struct {};

/// Initialize the thread stack.
pub fn initStack(_: []u8, _: anytype, _: anytype) []u8 {
    @panic(todo);
}

/// Initialize the thread stack for a cloned child process.
pub fn initStackFork(_: []u8, _: *const IsrContext, _: usize, _: ?usize) []u8 {
    @panic(todo);
}

/// Initialize FPU state.
///
/// Returns the pointer to the initialized FPU state.
pub fn initFpu(_: Allocator) Allocator.Error!*anyopaque {
    @panic(todo);
}

/// Release the FPU state.
pub fn deinitFpu(_: *anyopaque, _: Allocator) void {
    @panic(todo);
}

/// Restore the FPU state of the current thread using the given saved state.
pub fn restoreFpu(_: *anyopaque) void {
    @panic(todo);
}

/// Save the FPU state of the current thread into the given region.
pub fn saveFpu(_: *anyopaque) void {
    @panic(todo);
}

/// Get the size in bytes of the FPU state.
pub fn getFpuStateSize() usize {
    @panic(todo);
}

/// Get the user stack pointer recorded in the given ISR context.
pub fn userStackPointerOf(_: *const IsrContext) usize {
    @panic(todo);
}

/// Get the ISR context saved on the given kernel stack.
///
/// Valid only when called from a syscall handler.
pub fn isrContextOf(_: []u8) *IsrContext {
    @panic(todo);
}

/// Switch context from the calling thread to the new thread.
///
/// Must be called while IRQ disabled.
///
/// Returns the pointer to the previous thread's context.
pub fn switchContext(_: *usize, _: *const usize, _: usize, _: *anyopaque, _: ?*anyopaque) *anyopaque {
    @panic(todo);
}

/// Set the thread pointer for TLS.
pub fn setThreadPointer(_: usize) void {
    @panic(todo);
}

/// Drop to U-mode and start executing at the given user PC with the given user SP.
///
/// Does not return.
pub fn enterUserland(_: usize, _: usize, _: usize) noreturn {
    @panic(todo);
}

// =============================================================
// Imports
// =============================================================

const Allocator = @import("std").mem.Allocator;
const IsrContext = @import("isr.zig").Context;
