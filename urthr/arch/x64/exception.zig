/// Exception handler function signature.
///
/// Returns null if the exception cannot be handled.
pub const HandlerSignature = *const fn () ?void;

/// Initialize exception handling for this CPU.
pub fn initLocal() void {
    @panic("unimplemented");
}

/// Set the console used to print exception information.
pub fn setConsole(_: Console) void {
    @panic("unimplemented");
}

/// Set the terminator function called at the end of exception handlers.
pub fn setTerminator(_: anytype) void {
    @panic("unimplemented");
}

/// Set the exception handler function.
pub fn setHandler(_: HandlerSignature) void {
    @panic("unimplemented");
}

/// Set hook called before every return to EL0.
pub fn setEreturnHook(_: anytype) void {
    @panic("unimplemented");
}

/// Call the ERET hook if registered.
pub fn callEreturnHook() void {
    @panic("unimplemented");
}

/// Register context.
pub const Context = extern struct {};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const Console = common.Console;
const StackIterator = @import("StackIterator.zig");
