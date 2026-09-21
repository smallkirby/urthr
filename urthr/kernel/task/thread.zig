/// Thread instance.
pub const Thread = struct {
    /// Thread ID.
    id: Id,
    /// Parent TGID.
    ppid: Id,

    /// Thread name.
    name: []const u8,
    /// Thread state.
    state: State,
    /// Thread stack pointer.
    sp: usize,
    /// Stack memory region.
    stack: ?[]u8 = null,

    /// Exit status of this thread. Valid only when the state is `dead`.
    exit_status: ExitStatus = .{ .code = 0 },
    /// Completion to signal on exit or execve when created by a vfork.
    vfork_done: ?*VforkWaiter = null,

    /// User address to clear and futex-wake on exit.
    clear_child_tid: ?*u32 = null,
    /// Signal handling state.
    sigstate: signal.State,

    /// Parent's thread group
    ///
    /// Stays valid even after the specific thread that created this thread has exited.
    ///
    /// null for the idle thread, orphaned threads, and non-leader members of a thread group.
    parent: ?*task.ThreadGroup = null,
    /// Link node in the parent group's children list.
    sibling: ChildrenList.Head = .{},

    /// Thread group this thread belongs to.
    ///
    /// Shared by all threads in the same thread group.
    group: *task.ThreadGroup,
    /// Link node for thread group members list.
    tg_sibling: task.ThreadGroup.MemberList.Head = .{},

    /// This thread needs to be rescheduled.
    need_resched: bool = false,
    /// Total accumulated runtime in microseconds.
    runtime_us: u64 = 0,
    /// Raw timer ticks when this thread last started executing.
    last_exec_start: u64 = 0,
    /// CPU affinity mask.
    affinity: u64 = ~@as(u64, 0),

    /// Memory manager.
    vmm: *task.Vmm,
    /// File system information.
    fs: ThreadFs,

    /// Thread list node.
    head: ThreadList.Head = .{},

    comptime {
        if (board.num_cpus > @bitSizeOf(@FieldType(Thread, "affinity"))) {
            @compileError("Affinity mask is too small to represent all cores.");
        }
    }
};

/// Default stack size for threads.
pub const default_stack_size = 64 * 1024; // 64 KiB

/// Thread ID type.
///
/// This value is purely unique for each thread until wrapped around.
pub const Id = u32;
/// Thread group ID type.
///
/// This is PID from userspace perspective.
/// For single-threaded processes this equals the thread ID.
pub const Tgid = u32;
/// Process group ID.
///
/// Collection of one or more threads that can receive signals together (job).
pub const Pgid = u32;
/// Session ID.
///
/// Collection of one or more process groups.
/// Shares only one controlling terminal by threads in the same session.
/// Cannot join a process group from a different session.
pub const Sid = u32;

/// Thread state.
pub const State = enum {
    /// Thread is currently running or ready in the runqueue.
    running,
    /// Thread is blocked, waiting for an event.
    blocked,
    /// Thread has finished execution as the group's leader,
    /// and waiting to become zombie after switched-out.
    moribund,
    /// Thread has finished execution but is waiting for the parent to collect.
    zombie,
    /// Thread has finished execution and is ready to be cleaned up.
    dead,
};

/// Exit status.
pub const ExitStatus = union(enum) {
    /// Normal exit status.
    code: i32,
    /// Signal that terminated this thread.
    signal: Signal,
};

/// Wait-queue used by a parent to wait for a vfork-cloned child.
pub const VforkWaiter = struct {
    /// Lock protecting this completion.
    lock: SpinLock = .{},
    /// Queue the parent waits on.
    cv: CondVar = .{},
    /// Set when the child has exited or called execve.
    done: bool = false,

    /// Mark as completed and wake the waiting parent.
    pub fn complete(self: *VforkWaiter) void {
        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);

        self.done = true;
        self.cv.signal();
    }

    /// Block until the child signals completion.
    pub fn wait(self: *VforkWaiter) void {
        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);

        while (!self.done) {
            self.cv.wait(&self.lock);
        }
    }
};

/// Thread FS information.
pub const ThreadFs = struct {
    /// FS information.
    info: *FsInfo,
    /// File descriptor table.
    fdtbl: *FdTable,
};

/// FS information possibly shared among threads.
pub const FsInfo = struct {
    /// Root directory of this thread.
    root: urd.fs.Path,
    /// Current working directory of this thread.
    cwd: urd.fs.Path,
    /// File mode creation mask.
    umask: urd.fs.FileMode = .default,
    /// Number of threads sharing this instance.
    refcnt: usize = 1,
    /// Protects access to this instance.
    _lock: SpinLock = .{},

    /// Create a new instance.
    pub fn new(allocator: Allocator, root: urd.fs.Path, cwd: urd.fs.Path) Allocator.Error!*FsInfo {
        const self = try allocator.create(FsInfo);
        self.* = .{ .root = root, .cwd = cwd };
        return self;
    }

    /// Increment the reference count to share this instance.
    pub fn ref(self: *FsInfo) *FsInfo {
        const ie = self._lock.lockDisableIrq();
        defer self._lock.unlockRestoreIrq(ie);
        self.refcnt += 1;
        return self;
    }

    /// Create an independent copy of this instance.
    pub fn clone(self: *FsInfo, allocator: Allocator) Allocator.Error!*FsInfo {
        self.root.dentry.ref();
        self.cwd.dentry.ref();
        const copy = allocator.create(FsInfo) catch |err| {
            self.root.dentry.unref();
            self.cwd.dentry.unref();
            return err;
        };
        copy.* = .{
            .root = self.root,
            .cwd = self.cwd,
            .umask = self.umask,
        };
        return copy;
    }

    /// Drop a reference to this instance, releasing its resources once unreferenced.
    pub fn deinit(self: *FsInfo, allocator: Allocator) void {
        const ie = self._lock.lockDisableIrq();
        const last = self.refcnt == 1;
        self.refcnt -= 1;
        self._lock.unlockRestoreIrq(ie);
        if (!last) return;

        self.root.dentry.unref();
        self.cwd.dentry.unref();
        allocator.destroy(self);
    }
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

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const typing = common.typing;
const arch = @import("arch").impl;
const board = @import("board").impl;
const urd = @import("urthr");
const task = urd.task;
const sync = urd.sync;
const CondVar = urd.sync.CondVar;
const FdTable = urd.fs.FdTable;
const SpinLock = sync.SpinLock;
const signal = @import("signal.zig");
const Signal = signal.Signal;
