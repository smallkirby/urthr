//! Handles secondary core bringup sequence.

/// Secondary cores use this data to set up their execution environment
const SmpBootData = extern struct {
    /// Value of shared kernel CR3.
    cr3: u64,
    /// Virtual address of the AP's stack bottom.
    stack: u64,
    /// Virtual address of the Zig entry point.
    entry: u64,
};
extern const _boot_data: SmpBootData;

/// Subcore entry point.
extern fn _substart() callconv(.naked) void;
/// End of the subcore entry point;
extern const _subend: void;

/// Physical address at which the real-mode trampoline code is loaded.
pub var trampoline_phys: usize = undefined;
/// Trampoline code loaded into low memory (< 1MiB).
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

/// Wake up a secondary core.
pub fn wakeSubcore(core: usize, entry: usize, stack: usize) void {
    rtt.expect(core != 0);
    rtt.expect(stack % 16 == 0);
    rtt.expect(trampoline.len >= trampolineSize());

    // Initialize boot data.
    const boot_data: *volatile SmpBootData = @ptrCast(@alignCast(trampoline.ptr + bootDataOffset()));
    boot_data.* = .{
        .entry = entry,
        .stack = stack - 8,
        .cr3 = am.readCr3(),
    };

    // Wake up secondary core.
    const dest: u8 = @intCast(core);
    lapic.wakeCore(dest, trampoline_phys);
}

/// Called by a secondary core after it has been woken up.
pub fn localInit(cpu: usize) void {
    // Initialize GDT and TSS for this CPU.
    gdt.localInit(cpu);
}

/// Get the offset of the boot data within the trampoline blob.
fn bootDataOffset() usize {
    return @intFromPtr(&_boot_data) - @intFromPtr(&_substart);
}

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const rtt = common.rtt;
const am = @import("asm.zig");
const gdt = @import("gdt.zig");
const lapic = @import("lapic.zig");
