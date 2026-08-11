test "syscall: sethostname updates the hostname" {
    var orig = std.mem.zeroes(linux.utsname);
    try testing.expectEqual(.SUCCESS, linux.errno(linux.uname(&orig)));
    const orig_name = std.mem.sliceTo(&orig.nodename, 0);
    defer setHostname(orig_name) catch unreachable;

    try setHostname("myhost");

    var uts = std.mem.zeroes(linux.utsname);
    try testing.expectEqual(.SUCCESS, linux.errno(linux.uname(&uts)));
    try testing.expectEqualStrings("myhost", std.mem.sliceTo(&uts.nodename, 0));
}

test "sethostname rejects a name longer than the maximum host name length" {
    var orig = std.mem.zeroes(linux.utsname);
    try testing.expectEqual(.SUCCESS, linux.errno(linux.uname(&orig)));
    const orig_name = std.mem.sliceTo(&orig.nodename, 0);
    defer setHostname(orig_name) catch unreachable;

    const too_long = [_]u8{'a'} ** 65;
    const ret = linux.syscall2(.sethostname, @intFromPtr(&too_long), too_long.len);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

// =============================================================
// Helpers
// =============================================================

fn setHostname(name: []const u8) !void {
    const ret = linux.syscall2(.sethostname, @intFromPtr(name.ptr), name.len);
    if (linux.errno(ret) != .SUCCESS) return error.SetHostnameFailed;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
