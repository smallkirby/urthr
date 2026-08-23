comptime {
    _ = @import("sched/sched_getaffinity.zig");
    _ = @import("sched/sched_setaffinity.zig");
    _ = @import("sched/sched_yield.zig");
}
