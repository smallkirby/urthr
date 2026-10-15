//! Arbitrary performance tracer client.

const size_buf: usize = 4096 * 16;
var buf: [4096 * 16]u8 = undefined;

/// Fetches the current performance data.
pub fn fetch(allocator: Allocator) Allocator.Error!Iterator {
    const nbytes = try aperf();
    const data = try allocator.dupe(u8, buf[0..nbytes]);
    errdefer allocator.free(data);

    return .{
        ._data = data,
        ._allocator = allocator,
    };
}

/// Clear all recorded events.
pub fn clear() void {
    _ = aperf() catch @panic("Failed to clear aperf");
}

pub const Record = struct {
    name: []const u8,
    count: u64,
    ns: u128,
};

pub const Iterator = struct {
    _data: []const u8,
    _allocator: Allocator,
    _consumed: usize = 0,

    pub fn next(self: *Iterator) ?Record {
        if (self._consumed >= self._data.len) {
            return null;
        }

        const remain = self._data[self._consumed..];
        const rec: *align(1) const common.perf.AperfRecord = @ptrCast(remain.ptr);
        defer self._consumed += @sizeOf(common.perf.AperfRecord) + rec.name_size;
        return .{
            .name = @as([*]const u8, @ptrCast(&rec.__name))[0..rec.name_size],
            .count = rec.count,
            .ns = rec.ns,
        };
    }

    pub fn deinit(self: *Iterator) void {
        self._allocator.free(self._data);
    }
};

/// Raw syscall interface.
fn aperf() !u64 {
    const aperf_num = 514;

    const ret = switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\syscall
            : [ret] "={rax}" (-> u64),
            : [number] "{rax}" (aperf_num),
              [arg1] "{rdi}" (@intFromPtr(&buf)),
              [arg2] "{rsi}" (size_buf),
            : .{ .rcx = true, .r11 = true, .memory = true }),
        .aarch64 => asm volatile (
            \\svc #0
            : [ret] "={x0}" (-> u64),
            : [number] "{x8}" (aperf_num),
              [arg1] "{x0}" (@intFromPtr(&buf)),
              [arg2] "{x1}" (size_buf),
            : .{ .memory = true }),
        else => @compileError("Unsupported architecture"),
    };

    if (linux.errno(ret) != .SUCCESS) {
        @panic("aperf syscall failed");
    }
    return @intCast(ret);
}

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const common = @import("common");
