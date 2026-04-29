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

// =============================================================
// Imports
// =============================================================

const std = @import("std");
