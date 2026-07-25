/// SVC handler function type.
///
/// When null is returned, X0 is not modified and returned as-is to user.
const HandlerFn = fn (
    nr: u64,
    arg1: u64,
    arg2: u64,
    arg3: u64,
    arg4: u64,
    arg5: u64,
    arg6: u64,
) ?i64;

/// SVC dispatcher.
var dispatcher: *const HandlerFn = undefined;

/// Set SVC handler function.
pub fn setHandler(f: *const HandlerFn) void {
    dispatcher = f;
}
