/// System call: sched_getaffinity
pub fn sysSchedGetAffinity(pid: usize, size: usize, mask: [*]CpuSet) ReturnType {
    _ = pid;

    const num_sets = size / @sizeOf(CpuSet);
    if (num_sets == 0) {
        return .err(.inval);
    }

    const sets = mask[0..num_sets];
    for (sets) |*set| {
        set.clear();
    }

    // TODO: mark only Core#0 as available for now.
    sets[0].bits[0] = bits.set(sets[0].bits[0], 0);

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
const urd = @import("urthr");
const ReturnType = urd.syscall.ReturnType;
