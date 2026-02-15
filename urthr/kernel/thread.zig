//! Thread instance.
pub const Thread = struct {
    /// Thread ID.
    id: Id,
    /// Thread name.
    name: []const u8,
    /// Thread state.
    state: State,
    /// Thread stack pointer.
    sp: usize,
    /// Stack memory region.
    stack: ?[]u8 = null,
    /// This thread needs to be rescheduled.
    need_resched: bool = false,
    /// Thread list node.
    head: ThreadList.Head = .{},
};

/// Default stack size for threads.
pub const default_stack_size = 16 * 1024; // 16 KiB

/// Thread identifier.
pub const Id = u32;

/// Thread state.
pub const State = enum {
    /// Thread is ready to run.
    ready,
    /// Thread is currently running.
    running,
    /// Thread is blocked, waiting for an event.
    blocked,
    /// Thread has finished execution and is waiting to be cleaned up.
    dead,
};

/// Thread function type.
pub const ThreadFn = *const fn (?*anyopaque) callconv(.c) void;

/// List type of threads.
pub const ThreadList = typing.InlineDoublyLinkedList(Thread, "head");

// =============================================================
// Imports
// =============================================================

const urd = @import("urthr");
const common = @import("common");
const typing = common.typing;
