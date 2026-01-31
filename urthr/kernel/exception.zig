pub const Error = error{
    /// An interrupt handler is already registered for the given vector.
    AlreadyRegistered,
};

/// Interrupt handler function signature.
pub const Handler = *const fn () void;

/// Interrupt vector table defined by Norn.
pub const Vector = enum(u16) {
    hoge = 1,
    /// Spurious interrupt.
    spurious = num_interrupts - 1,
};

/// Number of supported exceptions.
const num_interrupts = 512;

/// Interrupt handlers.
var handlers: [num_interrupts]?Handler = [_]?Handler{null} ** num_interrupts;

/// Initialize the basic exception handling for booting the kernel.
///
/// IRQs are not enabled yet.
pub fn boot() void {
    arch.exception.setConsole(board.getConsole());
    arch.exception.initLocal();

    // Set terminator function.
    arch.exception.setTerminator(urd.eol);

    // Set handler function.
    board.setIrqHandler(call);
}

/// Initialize local IRQ handling.
///
/// IRQs are still masked at this point.
pub fn initLocal() void {
    board.initIrqLocal();
}

/// Call the registered interrupt handler for the given vector.
///
/// Returns null if no handler is registered.
fn call(vector: u64) ?void {
    // Call corresponding handler.
    if (handlers[vector]) |handler| {
        handler();
    } else {
        return null;
    }
}

/// Set an interrupt handler for the given vector.
///
/// Fails if a handler is already registered for the vector.
pub fn setHandler(vector: Vector, handler: Handler) Error!void {
    if (handlers[@intFromEnum(vector)] != null) {
        return Error.AlreadyRegistered;
    }
    handlers[@intFromEnum(vector)] = handler;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const board = @import("board").impl;
const arch = @import("arch").impl;
const urd = @import("urthr");
