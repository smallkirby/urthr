pub fn scoped(comptime domain: @Type(.enum_literal), comptime scope: @Type(.enum_literal)) Logger {
    return struct {
        fn f(comptime fmt: []const u8, args: anytype) void {
            if (isEnabled(domain)) {
                klog.anyLog("TRACE", scope, fmt, args);
            }
        }
    }.f;
}

const Logger = *const fn (comptime fmt: []const u8, args: anytype) void;

fn isEnabled(comptime domain: @Type(.enum_literal)) bool {
    for (traces) |d| {
        if (std.mem.eql(u8, @tagName(domain), d)) {
            return true;
        }
    }
    return false;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const options = @import("options");
const traces = options.trace;
const urd = @import("urthr");
const klog = urd.klog;
