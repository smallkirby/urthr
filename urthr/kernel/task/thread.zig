//! Thread instance.
pub const Thread = struct {
    /// Thread ID.
    id: Id,
    /// Thread Group ID (PID from userspace perspective).
    ///
    /// For single-threaded processes this equals `id`.
    /// Threads created via clone(CLONE_THREAD) share the TGID of the creator.
    tgid: Id,
    /// Parent thread group ID.
    ppid: Id,
    /// Process group ID.
    pgid: Id,
    /// Session ID.
    sid: Id,

    /// Thread name.
    name: []const u8,
    /// Thread state.
    state: State,
    /// Thread stack pointer.
    sp: usize,
    /// Stack memory region.
    stack: ?[]u8 = null,

    /// Exit status of this thread. Valid only when the state is `dead`.
    exit_status: i32 = 0,
    /// Completion to signal on exit or execve when created by a vfork.
    vfork_done: ?*VforkWaiter = null,

    /// Pointer to the parent thread. null for the idle thread and orphaned threads.
    ///
    /// TODO: becomes dangling if the parent exits while this thread is still alive.
    /// Reattaching the child to init thread is not yet implemented.
    parent: ?*Thread = null,
    /// List of live children.
    children: ChildrenList = .{},
    /// Link node in parent's children list.
    sibling: ChildrenList.Head = .{},
    /// Wait queue the parent blocks on to wait for the child to exit.
    child_exit_wq: WaitQueue = .{},

    /// This thread needs to be rescheduled.
    need_resched: bool = false,
    /// Total accumulated runtime in microseconds.
    runtime_us: u64 = 0,
    /// Raw timer ticks when this thread last started executing.
    last_exec_start: u64 = 0,

    /// Memory manager.
    vmm: *task.Vmm,
    /// File system information.
    fs: ThreadFs,

    /// Thread list node.
    head: ThreadList.Head = .{},
};

/// Default stack size for threads.
pub const default_stack_size = 64 * 1024; // 64 KiB

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

/// Wait-queue used by a parent to wait for a vfork-cloned child.
pub const VforkWaiter = struct {
    /// Lock protecting this completion.
    lock: urd.SpinLock = .{},
    /// Queue the parent waits on.
    wq: urd.WaitQueue = .{},
    /// Set when the child has exited or called execve.
    done: bool = false,

    /// Mark as completed and wake the waiting parent.
    pub fn complete(self: *VforkWaiter) void {
        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);

        self.done = true;
        _ = self.wq.wake();
    }

    /// Block until the child signals completion.
    pub fn wait(self: *VforkWaiter) void {
        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);

        while (!self.done) {
            self.wq.wait(&self.lock);
        }
    }
};

/// Thread FS information.
pub const ThreadFs = struct {
    /// Root directory of this thread.
    root: urd.fs.Path,
    /// Current working directory of this thread.
    cwd: urd.fs.Path,
    /// File descriptor table.
    fdtbl: urd.fs.FdTable = .{},
};

/// Thread function type.
pub const ThreadFn = *const fn (?*anyopaque) callconv(.c) void;

/// List type of threads.
pub const ThreadList = typing.InlineDoublyLinkedList(Thread, "head");

/// List type for parent's live-children list.
pub const ChildrenList = typing.InlineDoublyLinkedList(Thread, "sibling");

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const typing = common.typing;
const arch = @import("arch").impl;
const urd = @import("urthr");
const task = urd.task;
const WaitQueue = urd.WaitQueue;
