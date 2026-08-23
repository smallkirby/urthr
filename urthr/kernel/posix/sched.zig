/// syscall: sched_yield
pub fn sysSchedYield() ReturnType {
    sched.reschedule();
    return .success(0);
}

/// syscall: sched_getaffinity
pub fn sysSchedGetAffinity(pid: usize, size: usize, mask: [*]CpuSet) ReturnType {
    const cur = sched.getCurrent();
    const rpid = if (pid == 0) cur.id else pid;
    if (rpid != cur.id) {
        return .err(.perm);
    }

    const num_sets = size / @sizeOf(CpuSet);
    if (num_sets == 0) {
        return .err(.inval);
    }

    const sets = mask[0..num_sets];
    for (sets) |*set| {
        set.clear();
    }

    // Mark all cores participating in scheduling.
    for (0..board.num_cpus) |i| {
        const word = i / @bitSizeOf(CpuMaskT);
        const bit = i % @bitSizeOf(CpuMaskT);
        sets[0].bits[word] = bits.set(sets[0].bits[word], bit);
    }

    return .success(@intCast(num_sets * @sizeOf(CpuSet)));
}

/// The number of CPUs that can be represented in a CPU set.
const cpu_set_size = 1024;

/// Integer type that represents a CPU affinity mask.
const CpuMaskT = u64;

/// CPU set type.
const CpuSet = extern struct {
    bits: [cpu_set_size / @bitSizeOf(CpuMaskT)]CpuMaskT,

    comptime {
        urd.comptimeAssert(@bitSizeOf(CpuSet) == cpu_set_size, "Size of CpuSet.", .{});
    }

    /// Clear all bits of the CPU set.
    pub fn clear(self: *CpuSet) void {
        self.bits = std.mem.zeroes(@TypeOf(self.bits));
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const bits = common.bits;
const board = @import("board").impl;
const urd = @import("urthr");
const sched = urd.sched;
const ReturnType = urd.syscall.ReturnType;
