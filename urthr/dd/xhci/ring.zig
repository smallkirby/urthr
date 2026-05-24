/// Ring that can be used both for Command Ring and Transfer Ring.
///
/// - Command Ring is used by software to pass device and HC related command to the xHC.
/// - Transfer Ring is used by software to schedule work items for a single USB Endpoint.
pub const Ring = struct {
    /// Buffers for TRB.
    trbs: []volatile Trb,
    /// Producer Cycle State.
    pcs: u1 = 1,
    /// Next index to write to.
    index: usize = 0,

    /// Initialize a new Ring.
    pub fn new(comptime size: usize, allocator: PageAllocator) mem.Error!Ring {
        const buf = try allocator.alloc(Trb, size);
        errdefer allocator.free(buf);
        @memset(@as([*]u8, @ptrCast(buf.ptr))[0 .. buf.len * @sizeOf(Trb)], 0);

        return .{ .trbs = buf };
    }

    /// Enqueue a TRB to the Ring.
    ///
    /// CRB of the TRB is properly set.
    /// TRB is copied, so the argument can be located in the stack.
    pub fn push(self: *Ring, trb: *Trb) *const Trb {
        // Copy the TRB to the tail of the Ring.
        const ret = self.copyToTail(trb);

        // Increment cursor.
        self.index += 1;
        if (self.index == self.trbs.len - 1) {
            self.rotate();
        }

        return ret;
    }

    /// Copy a TRB to the tail of the Ring pointed to by the index.
    fn copyToTail(self: *Ring, trb: *Trb) *const Trb {
        // Set the cycle bit.
        trb.cycle = self.pcs;

        // Copy the TRB.
        self.trbs[self.index] = trb.*;

        return @ptrCast(@volatileCast(&self.trbs[self.index]));
    }

    /// Push a Link TRB and reset the cursor.
    fn rotate(self: *Ring) void {
        rtt.expect(self.index == self.trbs.len - 1);
        var link = trbs.LinkTrb.new(self.trbs);
        _ = self.copyToTail(@ptrCast(&link));
        self.pcs +%= 1;
        self.index = 0;
    }

    /// Deinitialize the Ring and free the backing memory.
    pub fn deinit(self: *Ring, allocator: PageAllocator) void {
        self.trbs = undefined;
        allocator.free(self.trbs);
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.xhc);
const common = @import("common");
const PageAllocator = common.mem.PageAllocator;
const rtt = common.rtt;
const urd = @import("urthr");
const mem = urd.mem;
const trbs = @import("trb.zig");
const Trb = trbs.Trb;
