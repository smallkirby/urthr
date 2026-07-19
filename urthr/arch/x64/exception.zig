/// Exception handler function signature.
///
/// Returns null if the exception cannot be handled.
pub const HandlerSignature = *const fn () ?void;

/// Function pointer to the registered exception handler.
var handler: ?HandlerSignature = null;

/// Called when an exception handler reaches the end.
var terminator: ?*const fn (u8) void = null;

/// Initialize exception handling for this CPU.
pub fn initLocal() void {
    @panic("unimplemented");
}

/// Set the console used to print exception information.
pub fn setConsole(c: Console) void {
    console = c;
}

/// Set the terminator function called at the end of exception handlers.
pub fn setTerminator(f: @TypeOf(terminator)) void {
    terminator = f;
}

/// Set the exception handler function.
pub fn setHandler(h: HandlerSignature) void {
    handler = h;
}

/// Set hook called before every return to EL0.
pub fn setEreturnHook(_: anytype) void {
    @panic("unimplemented");
}

/// Call the ERET hook if registered.
pub fn callEreturnHook() void {
    @panic("unimplemented");
}

/// Console instance used to print exception information.
///
/// Must be set by the kernel before any exception occurs.
var console: Console = undefined;

/// Register context.
pub const Context = extern struct {};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const Console = common.Console;
const StackIterator = @import("StackIterator.zig");
