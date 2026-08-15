//! Shared state for a thread group.
//!
//! All threads sharing a TGID hold a reference to the same this struct.

const Self = @This();

/// Reference count.
///
/// The group is freed when it drops to zero.
_refcnt: usize = 1,
/// The original thread on creation of this group.
///
/// This field is never reassigned even if the thread exits before the rest of the group.
/// So leader's TID is always equal to the group's TGID.
_leader: *Thread,
/// Live, not yet exited, members of this group.
_members: MemberList = .{},
/// Indicates that every member should terminate.
_dying: bool = false,
/// Exit status for all members of this group.
_exit_status: thread.ExitStatus = .{ .code = 0 },

/// Protects fields of this struct.
_lock: SpinLock = .{},

/// List of threads sharing the same thread group.
pub const MemberList = typing.InlineDoublyLinkedList(Thread, "tg_sibling");

/// Create a new thread group whose sole member and leader is `leader`.
///
/// The caller is responsible for adding `leader` to `members` once it has been fully initialized.
pub fn new(allocator: Allocator, leader: *Thread) Allocator.Error!*Self {
    const self = try allocator.create(Self);
    self.* = .{ ._leader = leader };
    return self;
}

/// Increment the reference count to share this thread group.
pub fn ref(self: *Self) *Self {
    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);
    self._refcnt += 1;
    return self;
}

/// Decrement the reference count, freeing the group when it reaches zero.
pub fn deref(self: *Self, allocator: Allocator) void {
    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);

    self._refcnt -= 1;
    if (self._refcnt == 0) {
        allocator.destroy(self);
    }
}

/// Get a thread leader whose TID is equal to this group's TGID.
pub fn getLeader(self: *const Self) *Thread {
    return self._leader;
}

/// Add a fully-initialized thread to this group's live members.
pub fn addMember(self: *Self, th: *Thread) void {
    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);
    self._members.append(th);
}

/// Remove the thread from this group's live members.
///
/// Returns whether the thread was the last live member.
pub fn leave(self: *Self, th: *Thread) bool {
    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);
    self._members.remove(th);
    return self._members.isEmpty();
}

/// Mark every member of this group for termination with the given status.
pub fn markDying(self: *Self, status: thread.ExitStatus) void {
    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);
    self._dying = true;
    self._exit_status = status;
}

/// Get the exit status for this group if it is marked dying.
pub fn dyingStatus(self: *const Self) ?thread.ExitStatus {
    return if (self._dying) self._exit_status else null;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const typing = common.typing;
const urd = @import("urthr");
const SpinLock = urd.sync.SpinLock;
const thread = @import("thread.zig");
const Thread = thread.Thread;
