//! This file provides per-CPU data access.
//!
//! Per-CPU variable can be defined by adding `linksection(pcpu.section)` to the variable.
//! These variables are placed in the `.data..percpu` section.

/// Section name where per-CPU data is placed.
pub const section = ".data..percpu";

/// Alignment of per-CPU data.
const percpu_align = urd.mem.size_4kib;

/// Start address of initial per-CPU data.
extern const __per_cpu_start: void;
/// End address of initial per-CPU data.
extern const __per_cpu_end: void;

/// Offsets of per-CPU data.
var cpu_offsets = [_]usize{0} ** board.num_cpus;

/// Per-CPU data instance.
var percpu_instance: []u8 = undefined;

/// Initialize per-CPU data.
pub fn globalInit(allocator: PageAllocator) PageAllocator.Error!void {
    rtt.expectEqual(false, percpu_initialized);

    const per_cpu_size = @intFromPtr(&__per_cpu_end) - @intFromPtr(&__per_cpu_start);
    if (per_cpu_size == 0) {
        percpu_initialized = true;
        return;
    }

    // Calculate offsets of per-CPU data.
    for (0..board.num_cpus) |i| {
        const offset = if (i == 0) 0 else cpu_offsets[i - 1] + per_cpu_size;
        cpu_offsets[i] = std.mem.alignForward(usize, offset, percpu_align);
    }

    // Allocate per-CPU data area.
    const total_size = cpu_offsets[board.num_cpus - 1] + per_cpu_size;
    percpu_instance = try allocator.allocBytesV(total_size - 1);
    log.debug("Per-CPU storage allocated at 0x{X}", .{@intFromPtr(percpu_instance.ptr)});

    // Copy initial data to per-CPU data.
    const original_data: [*]const u8 = @ptrCast(&__per_cpu_start);
    for (0..board.num_cpus) |i| {
        @memcpy(rawGetCpuHead(i)[0..per_cpu_size], original_data[0..per_cpu_size]);
    }

    percpu_initialized = true;

    // TODO: make the initial per-CPU data area non-accessible.
}

/// Initialize per-CPU data for this core.
pub fn localInit(cpu: usize) void {
    rtt.expectEqual(true, percpu_initialized);
    rtt.expectEqual(false, percpu_thiscpu_initialized[cpu]);

    if (@intFromPtr(&__per_cpu_end) - @intFromPtr(&__per_cpu_start) == 0) {
        percpu_thiscpu_initialized[cpu] = true;
        return;
    }

    arch.setPerCpuBase(@intFromPtr(rawGetCpuHead(cpu)) -% @intFromPtr(&__per_cpu_start));

    percpu_thiscpu_initialized[cpu] = true;
}

// =============================================================
// Accessors
// =============================================================

/// Get the address of the per-CPU variable.
pub inline fn ptr(comptime pointer: anytype) @TypeOf(pointer) {
    return @ptrFromInt(arch.getPerCpuBase() +% @intFromPtr(pointer));
}

/// Get the value of the per-CPU variable.
pub inline fn get(comptime pointer: anytype) @typeInfo(@TypeOf(pointer)).pointer.child {
    return ptr(pointer).*;
}

/// Get the virtual address of per-CPU data area for the given CPU.
inline fn rawGetCpuHead(cpu: usize) [*]u8 {
    return @ptrFromInt(@intFromPtr(percpu_instance.ptr) +% cpu_offsets[cpu]);
}

// =============================================================
// Runtime tests
// =============================================================

/// Whether per-CPU data is initialized globally.
var percpu_initialized: bool = false;
/// Whether per-CPU data is initialized for each CPU.
var percpu_thiscpu_initialized = [_]bool{false} ** board.num_cpus;

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.pcpu);
const common = @import("common");
const rtt = common.rtt;
const PageAllocator = common.mem.PageAllocator;
const arch = @import("arch").impl;
const board = @import("board").impl;
const urd = @import("urthr");
