comptime {
    _ = @import("task/getpid.zig");
    _ = @import("task/gettid.zig");
    _ = @import("task/getuid.zig");
    _ = @import("task/geteuid.zig");
    _ = @import("task/getpgid.zig");
    _ = @import("task/getsid.zig");
    _ = @import("task/prlimit64.zig");
    _ = @import("task/setpgid.zig");
    _ = @import("task/setsid.zig");
    _ = @import("task/wait4.zig");
}
