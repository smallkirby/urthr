pub const Error = error{
    /// Address is not mapped or not aligned.
    InvalidAddress,
    /// Failed to allocate memory.
    OutOfMemory,
    /// The futex value did not match the expected value.
    NotExpected,
};

/// Wait for the futex at the given address.
///
/// `deadline_ns` is absolute time in nanoseconds by which the wait should time out.
pub fn wait(addr: FutexAddress, expected: usize, vmm: *Vmm, deadline_ns: ?u64) Error!void {
    if (deadline_ns != null) urd.unimplemented("futex.wait with deadline");

    // Calculate kernel linear address of the futex.
    const phys = arch.mmu.translateWalk(vmm.as, addr, mem.page) orelse {
        return Error.InvalidAddress;
    };
    if (phys % @sizeOf(FutexValue) != 0) {
        return Error.InvalidAddress;
    }
    const linear = phys + mem.vmap.linear.start;

    // Lock the futex entry list.
    const eptr = map.get(linear);
    var ie = eptr.lock.lockDisableIrq();

    // Check if the futex value matches the expected value.
    const fptr: *std.atomic.Value(FutexValue) = @ptrFromInt(linear);
    if (fptr.load(.acquire) != expected) {
        eptr.lock.unlockRestoreIrq(ie);
        return Error.NotExpected;
    }

    // Push the futex key into the entry list.
    const key = try eptr.keys.getOrAppend(linear);
    rtt.expectEqual(fptr, key.addr);

    // Add this thread to the futex waiters list.
    var waiter: FutexWaiter = .{ .th = sched.getCurrent() };
    key.waiters.append(&waiter);

    // Wait for the futex to be woken up.
    sched.blockCurrent(&eptr.lock);

    // Remove the waiter from the list.
    if (!waiter.removed) {
        ie = eptr.lock.lockDisableIrq();
        defer eptr.lock.unlockRestoreIrq(ie);
        key.waiters.remove(&waiter);
        waiter.removed = true;
    }
}

/// Wake up to `max` threads waiting on the futex at the given address.
///
/// Returns the number of threads that were woken up.
pub fn wake(addr: FutexAddress, vmm: *Vmm, max: usize) Error!usize {
    const phys = arch.mmu.translateWalk(vmm.as, addr, mem.page) orelse {
        return Error.InvalidAddress;
    };
    if (phys % @sizeOf(FutexValue) != 0) {
        return Error.InvalidAddress;
    }
    const linear = phys + mem.vmap.linear.start;

    const eptr = map.get(linear);
    const ie = eptr.lock.lockDisableIrq();
    defer eptr.lock.unlockRestoreIrq(ie);
    const key = eptr.keys.get(linear) orelse return 0;

    var woken: usize = 0;
    while (woken < max) : (woken += 1) {
        const waiter = key.waiters.pop() orelse break;
        waiter.removed = true;
        sched.wake(waiter.th);
    }

    return woken;
}

// =============================================================
// Internals
// =============================================================

/// Futex hash table instance.
var map: FutexMap = .{};

/// Address of a futex in the kernel's linear address space.
const FutexAddress = usize;
/// Value of a futex.
const FutexValue = u32;

/// Futex hash table type.
const FutexMap = struct {
    const capacity = 256;

    entries: [capacity]Entry = [_]Entry{.{}} ** capacity,

    pub fn get(self: *FutexMap, addr: FutexAddress) *Entry {
        const key = FutexKey{ .addr = @ptrFromInt(addr) };
        const hash = key.hash();
        const index = hash % capacity;
        return &self.entries[index];
    }

    const Entry = struct {
        /// Lock protecting the futex keys.
        lock: SpinLock = .{},
        /// Futex keys.
        keys: KeyList = .{},
    };
};

/// Key of a futex.
const FutexKey = struct {
    /// Kernel linear address of the futex.
    addr: *std.atomic.Value(FutexValue),
    /// Threads waiting on this futex.
    waiters: FutexWaiter.List = .{},

    pub fn hash(self: FutexKey) usize {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&self.addr));
    }
};

/// Waiter type waiting on a futex.
const FutexWaiter = struct {
    /// Waiting thread.
    th: *Thread,
    /// Whether this waiter has been removed from the waiters list.
    removed: bool = false,
    /// List head.
    head: List.Head = .{},

    const List = InlineDoublyLinkedList(FutexWaiter, "head");
};

/// List type of of futex keys.
const KeyList = struct {
    _items: std.array_list.Aligned(*FutexKey, null) = .empty,

    pub fn get(self: *KeyList, addr: FutexAddress) ?*FutexKey {
        for (self._items.items) |k| {
            if (@intFromPtr(k.addr) == addr) return k;
        } else return null;
    }

    pub fn getOrAppend(self: *KeyList, addr: FutexAddress) Error!*FutexKey {
        for (self._items.items) |k| {
            if (@intFromPtr(k.addr) == addr) return k;
        }

        const key = try mem.bin.create(FutexKey);
        key.* = .{
            .addr = @ptrFromInt(addr),
            .waiters = .{},
        };
        try self._items.append(mem.bin, key);

        return key;
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const arch = @import("arch").impl;
const common = @import("common");
const rtt = common.rtt;
const InlineDoublyLinkedList = common.typing.InlineDoublyLinkedList;
const urd = @import("urthr");
const mem = urd.mem;
const sched = urd.sched;
const sync = urd.sync;
const SpinLock = sync.SpinLock;
const Thread = urd.task.thread.Thread;
const Vmm = urd.task.Vmm;
