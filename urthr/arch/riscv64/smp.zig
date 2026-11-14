//! Handles subcore bringup sequence.

/// Hart IDs of all harts in the system.
var hart_ids: []const usize = &.{};

/// Secondary harts use this data to set up their execution environment.
const SmpBootData = extern struct {
    /// SATP.
    satp: u64,
    /// Virtual address of the Zig entry point.
    entry: u64,
    /// Virtual address of the stack for the secondary hart.
    stack: u64,
};
/// Boot data in the trampoline blob.
extern const _smp_boot_data: SmpBootData;

/// Subcore entry point.
extern fn _substart() callconv(.naked) void;
/// End of the subcore entry point.
extern const _subend: void;

/// Function signature of the subcore secondary entry point.
pub const EntryFn = fn () callconv(.c) noreturn;

/// Identity-mapped physical address at which the trampoline code is loaded.
pub var trampoline_phys: usize = undefined;
/// Trampoline code loaded into the page.
var trampoline: []u8 = &.{};

/// Get the size in bytes of the trampoline blob.
pub fn trampolineSize() usize {
    return @intFromPtr(&_subend) - @intFromPtr(&_substart);
}

/// Copy the trampoline blob into the given memory.
pub fn installTrampoline(dest: []u8) void {
    rtt.expect(dest.len >= trampolineSize());

    const src: [*]const u8 = @ptrCast(&_substart);
    @memcpy(dest[0..trampolineSize()], src[0..trampolineSize()]);
    trampoline = dest;
}

/// Wake up a secondary hart.
pub fn wake(hartid: usize, f: *const EntryFn, stack: usize) void {
    rtt.expect(hartid != am.csrr(.sscratch).value);
    rtt.expect(stack % 16 == 0);
    rtt.expect(trampoline.len >= trampolineSize());

    // Initialize boot data.
    const boot_data: *volatile SmpBootData = @ptrCast(@alignCast(trampoline.ptr + bootDataOffset()));
    boot_data.* = .{
        .satp = @bitCast(am.csrr(.satp)),
        .entry = @intFromPtr(f),
        .stack = stack,
    };

    // Ensure the boot data is visible to the secondary hart.
    asm volatile ("fence rw, rw" ::: .{ .memory = true });

    // Request to start the hart.
    sbi.hartStart(hartid, trampoline_phys, 0) catch |err| {
        log.err("Failed to start hart#{d}: {}", .{ hartid, err });
        @panic("Aborting.");
    };
}

/// Called by a secondary core after it has been woken up.
pub fn localInit(_: usize) void {}

/// Tell the hart IDs of this platform.
pub fn setHartIds(ids: []const usize) void {
    hart_ids = ids;
}

/// Check if the given hart ID is a known hart.
pub fn isKnownHart(hartid: usize) bool {
    return std.mem.indexOfScalar(usize, hart_ids, hartid) != null;
}

/// Get the offset of the boot data within the trampoline blob.
fn bootDataOffset() usize {
    return @intFromPtr(&_smp_boot_data) - @intFromPtr(&_substart);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.rv64smp);
const common = @import("common");
const rtt = common.rtt;
const am = @import("asm.zig");
const sbi = @import("sbi.zig");
