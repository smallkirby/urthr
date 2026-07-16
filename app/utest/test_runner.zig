extern var utest_init_ptr: ?*std.process.Init;

const Tag = enum {
    /// Run only the specified test.
    only,
    /// Skip this test.
    skip,

    pub fn from(s: []const u8) ?Tag {
        if (std.mem.containsAtLeast(u8, s, 1, "tag:ONLY")) {
            return .only;
        }
        if (std.mem.containsAtLeast(u8, s, 1, "tag:SKIP")) {
            return .skip;
        }

        return null;
    }
};

var ok_count: usize = 0;
var skip_count: usize = 0;
var fail_count: usize = 0;

/// List of failed test names.
var fail_tests = std.array_list.Aligned([]const u8, null).empty;

pub fn main(init: std.process.Init) !void {
    @disableInstrumentation();
    log.info("Test Framework started.", .{});

    var init_var = init;
    utest_init_ptr = &init_var;

    // Find tag:ONLY tests.
    const has_tag_only = for (builtin.test_functions) |test_fn| {
        if (Tag.from(test_fn.name) == .only) {
            break true;
        }
    } else false;

    if (has_tag_only) {
        // Run only the tag:ONLY tests.
        log.info("Found tag:ONLY tests. Skipping other tests.", .{});
        for (builtin.test_functions) |test_fn| {
            if (Tag.from(test_fn.name) == .only) {
                runSingle(test_fn, init.gpa);
            }
        }
        std.process.exit(0);
    } else {
        // Run all tests.
        for (builtin.test_functions) |test_fn| {
            runSingle(test_fn, init.gpa);
        }
    }
    log.info("Summary: {d} passed, {d} skipped, {d} failed.", .{ ok_count, skip_count, fail_count });

    if (fail_count > 0) {
        for (fail_tests.items) |test_name| {
            log.info("  - {s}", .{test_name});
        }
        std.process.exit(1);
    } else {
        std.process.exit(0);
    }
}

/// Exit code a child process uses to report its test's outcome to the parent.
const TestResult = enum(u8) {
    /// The test passed.
    pass = 0,
    /// The test failed.
    fail = 1,
    /// The test was skipped.
    skip = 2,
};

/// Run a single test in its own forked process, isolating it from the rest of tests.
fn runSingle(test_fn: anytype, allocator: Allocator) void {
    log.info("RUN : {s}", .{test_fn.name});

    if (Tag.from(test_fn.name) == .skip) {
        log.info("SKIP: {s}", .{test_fn.name});
        skip_count += 1;
        return;
    }

    const pid = linux.fork();
    switch (linux.errno(pid)) {
        .SUCCESS => {},
        else => |err| {
            log.err("Failed to fork test process: {t}", .{err});
            @panic("utest failed.");
        },
    }

    // Child.
    if (pid == 0) {
        if (test_fn.func()) |_| {
            std.process.exit(@intFromEnum(TestResult.pass));
        } else |err| {
            if (err == error.SkipZigTest) {
                std.process.exit(@intFromEnum(TestResult.skip));
            } else {
                log.info("FAIL: {s} ({t})", .{ test_fn.name, err });
                std.process.exit(@intFromEnum(TestResult.fail));
            }
        }
        unreachable;
    }

    // Parent: wait for the child to finish.
    var status: u32 = undefined;
    const wret = linux.wait4(@intCast(pid), &status, 0, null);
    if (linux.errno(wret) != .SUCCESS) {
        log.err("Failed to wait for test process: {t}", .{linux.errno(wret)});
        @panic("utest failed.");
    }

    if (!std.posix.W.IFEXITED(status)) {
        log.err("Test process exited abnormally: status={d}", .{status});
        @panic("utest failed.");
    }

    const result: TestResult = switch (std.posix.W.EXITSTATUS(status)) {
        @intFromEnum(TestResult.pass) => .pass,
        @intFromEnum(TestResult.skip) => .skip,
        else => .fail,
    };
    switch (result) {
        .pass => {
            ok_count += 1;
            log.info("OK  : {s}", .{test_fn.name});
        },
        .skip => {
            skip_count += 1;
            log.info("SKIP: {s}", .{test_fn.name});
        },
        .fail => {
            fail_count += 1;
            fail_tests.append(allocator, test_fn.name) catch unreachable;
        },
    }
}

// =============================================================
// Panic
// =============================================================

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @branchHint(.cold);

    log.err("PANIC: {s}", .{msg});

    var it = StackIterator.init(@frameAddress());
    var ix: usize = 0;
    while (it.next()) |frame| : (ix += 1) {
        log.err("  #{d:0>2}: 0x{X:0>16}", .{ ix, frame });
    }

    std.posix.system.exit_group(99);
}

const StackIterator = struct {
    const Self = @This();

    fp: usize,

    pub fn init(start_fp: usize) Self {
        return .{ .fp = start_fp };
    }

    pub fn next(self: *Self) ?usize {
        const fp_addr = self.fp + 0;
        const ra_addr = self.fp + @sizeOf(usize);

        if (!isFrameValid(fp_addr, ra_addr)) {
            return null;
        }

        const fp_ptr: *const usize = @ptrFromInt(fp_addr);
        const ret_ptr: *const usize = @ptrFromInt(ra_addr);

        const fp = fp_ptr.*;
        const ra = ret_ptr.*;

        self.fp = fp;
        return ra;
    }

    fn isFrameValid(fp: usize, ra: usize) bool {
        return fp != 0 and
            ra != 0 and
            std.mem.isAligned(fp, @sizeOf(usize)) and
            std.mem.isAligned(ra, @sizeOf(usize)) and
            true;
    }
};

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const linux = std.os.linux;
const log = std.log.scoped(.utest);
const Allocator = std.mem.Allocator;
