extern var utest_init_ptr: ?*std.process.Init;

pub fn main(init: std.process.Init) !void {
    @disableInstrumentation();
    log.info("Test Framework started.", .{});

    var init_var = init;
    utest_init_ptr = &init_var;

    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;

    for (builtin.test_functions) |test_fn| {
        log.info("RUN : {s}", .{test_fn.name});

        if (test_fn.func()) |_| {
            ok_count += 1;
            log.info("OK  : {s}", .{test_fn.name});
        } else |err| {
            if (err != error.SkipZigTest) {
                fail_count += 1;
                log.info("FAIL: {s} ({t})", .{ test_fn.name, err });
            } else {
                skip_count += 1;
                log.info("SKIP: {s}", .{test_fn.name});
            }
        }
    }

    log.info("Summary: {d} passed, {d} skipped, {d} failed.", .{ ok_count, skip_count, fail_count });

    if (fail_count > 0) {
        std.process.exit(1);
    } else {
        std.process.exit(0);
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
const log = std.log.scoped(.utest);
