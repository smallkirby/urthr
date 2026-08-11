comptime {
    _ = @import("system/uname.zig");
    _ = @import("system/sethostname.zig");
    _ = @import("system/getrandom.zig");
}
