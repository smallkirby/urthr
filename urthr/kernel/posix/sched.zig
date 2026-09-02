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

    const uaddr = @intFromPtr(mask);
    if (!urd.uaccess.accessOk(uaddr, num_sets * @sizeOf(CpuSet))) {
        return .err(.fault);
    }

    // Report the affinity mask.
    var set: CpuSet = undefined;
    for (0..num_sets) |i| {
        set.clear();
        if (i == 0) set.bits[0] = cur.affinity & validCoreMask();

        urd.uaccess.putUser(
            CpuSet,
            uaddr + i * @sizeOf(CpuSet),
            set,
        ) catch return .err(.fault);
    }

    return .success(@intCast(num_sets * @sizeOf(CpuSet)));
}

/// syscall: sched_setaffinity
pub fn sysSchedSetAffinity(pid: usize, size: usize, mask: [*]const CpuSet) ReturnType {
    const cur = sched.getCurrent();
    const rpid = if (pid == 0) cur.id else pid;
    if (rpid != cur.id) {
        return .err(.perm);
    }

    const num_sets = size / @sizeOf(CpuSet);
    if (num_sets == 0) {
        return .err(.inval);
    }

    // Only bits corresponding to actually scheduled cores are meaningful.
    const kset = urd.uaccess.getUser(
        CpuSet,
        mask,
    ) catch return .err(.fault);
    const effective = kset.bits[0] & validCoreMask();
    if (effective == 0) {
        return .err(.inval);
    }

    // Set affinity mask for the current thread.
    sched.setAffinity(cur, effective);

    return .success(0);
}

/// syscall: getcpu
pub fn sysGetCpu(cpu: ?*align(1) u32, node: ?*align(1) u32) ReturnType {
    if (cpu) |p| {
        urd.uaccess.putUser(
            u32,
            p,
            @intCast(urd.smp.getLogicalCoreId()),
        ) catch return .err(.fault);
    }
    if (node) |p| {
        // No NUMA support
        urd.uaccess.putUser(
            u32,
            p,
            0,
        ) catch return .err(.fault);
    }

    return .success(0);
}

/// Get the mask of bits corresponding to cores actually participating in scheduling.
fn validCoreMask() CpuMaskT {
    return if (board.num_cpus >= @bitSizeOf(CpuMaskT))
        ~@as(CpuMaskT, 0)
    else
        (@as(CpuMaskT, 1) << @intCast(board.num_cpus)) - 1;
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
const board = @import("board").impl;
const urd = @import("urthr");
const sched = urd.sched;
const ReturnType = urd.syscall.ReturnType;
