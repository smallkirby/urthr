test "thread pinned to a single core is never observed running elsewhere" {
    try utest.runChild(struct {
        const pinned_cpu = 1;
        const num_samples = 2000;
        const num_competitors = 3;

        var stop = std.atomic.Value(bool).init(false);

        fn competitor(_: usize) callconv(.c) u8 {
            while (!stop.load(.acquire)) _ = linux.sched_yield();
            linux.exit(0);
        }

        pub fn lambda() !void {
            for (0..num_competitors) |_| {
                _ = try utest.task.spawnThread(competitor, 0);
            }

            var set: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
            set[pinned_cpu / @bitSizeOf(usize)] |= @as(usize, 1) << (pinned_cpu % @bitSizeOf(usize));
            try linux.sched_setaffinity(0, &set);

            for (0..num_samples) |_| {
                _ = linux.sched_yield();

                var cpu: usize = 0;
                _ = linux.getcpu(&cpu, null);
                try testing.expectEqual(@as(usize, pinned_cpu), cpu);
            }

            stop.store(true, .release);

            for (0..num_competitors) |_| {
                var status: u32 = undefined;
                _ = linux.wait4(-1, &status, 0, null);
            }
        }
    });
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
