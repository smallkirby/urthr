const todo = "TODO: RISC-V: trap handling is not supported yet";

/// Exception handler function signature.
///
/// Returns null if the exception cannot be handled.
pub const HandlerSignature = *const fn () ?void;

/// Page fault handler function signature.
///
/// Returns true if the fault was handled.
/// In that case, the faulting instruction can be safely retried,
/// or a signal has been queued for delivery).
///
/// Returns false if the fault is unrecoverable.
pub const PageFaultHandler = *const fn (far: usize, access: common.mem.AccessType, user: bool) bool;

/// User mode fault kinds.
pub const UserFault = enum {};

/// User fault handler function signature.
///
/// Called for synchronous exceptions taken from EL0, other than data aborts and SVC.
pub const UserFaultHandler = *const fn (kind: UserFault, addr: usize) void;

/// Hook function signature called before returning to U-mode.
pub const EreturnHook = *const fn (ctx: *Context) void;

/// Register context saved on a trap.
pub const Context = extern struct {};

/// Initialize exception handling for this CPU.
pub fn initLocal() void {
    @panic(todo);
}

/// Set the console used to print exception information.
pub fn setConsole(_: Console) void {}

/// Set the terminator function called at the end of exception handlers.
pub fn setTerminator(_: *const fn (u8) void) void {}

/// Get the state of the thread interrupted by an IRQ.
///
/// Available only while handling an IRQ.
pub fn getInterruptedInfo() ?common.arch.InterruptedInfo {
    @panic(todo);
}

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const Console = common.Console;
