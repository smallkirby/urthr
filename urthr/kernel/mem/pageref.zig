//! Manages references to physical pages shared by multiple mappings.
//!
//! Pages not managed by this module are implicitly owned by exactly one mapping.

/// Table of physical page address to its total number of owners.
const Table = std.AutoHashMap(usize, usize);

/// Table instance.
var table: Table = undefined;
/// Lock to protect the table.
var lock: SpinLock = .{};

/// Initialize the page reference table.
pub fn init(allocator: Allocator) void {
    table = .init(allocator);
}

/// Registers one additional owner for the physical page.
///
/// If the page is not intended to be shared, caller should not call this function.
pub fn share(pa: usize) Allocator.Error!void {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    const entry = try table.getOrPut(pa);
    entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 2;
}

/// Returns the number of owners of the physical page.
pub fn count(pa: usize) usize {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    return table.get(pa) orelse 1;
}

/// Drops one reference to the physical page.
///
/// Returns true if the caller was the last owner of the page,
/// meaning the caller is now responsible for freeing the physical page.
pub fn unref(pa: usize) bool {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);
    const entry = table.getEntry(pa) orelse return true;

    if (entry.value_ptr.* <= 2) {
        _ = table.remove(pa);
    } else {
        entry.value_ptr.* -= 1;
    }
    return false;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const urd = @import("urthr");
const SpinLock = urd.sync.SpinLock;
