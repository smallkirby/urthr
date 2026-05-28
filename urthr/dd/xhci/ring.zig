/// Number of TRBs that fit in one 4 KiB page.
pub const trbs_per_page = mem.page_size / @sizeOf(Trb);

/// Ring that can be used both for Command Ring and Transfer Ring.
///
/// #### Command Ring
///
/// Used by software to pass device and HC related command to the xHC.
///
///
/// #### Transfer Ring
///
/// Used by software to schedule work items for a single USB Endpoint.
///
pub const Ring = struct {
    /// Buffers for TRB.
    trbs: []volatile Trb,
    /// Producer Cycle State.
    pcs: u1 = 1,
    /// Next index to write to.
    index: usize = 0,

    /// Initialize a new Ring.
    pub fn new(size: usize, allocator: PageAllocator) mem.Error!Ring {
        const buf = try allocator.alloc(Trb, size);
        errdefer allocator.free(buf);
        for (buf) |*e| e.* = std.mem.zeroes(Trb);

        return .{ .trbs = buf };
    }

    /// Enqueue a TRB to the Ring.
    pub fn push(self: *Ring, value: *Trb) *const Trb {
        var trb = value;
        trb.cycle = self.pcs;

        const ret: *Trb = @ptrCast(@volatileCast(&self.trbs[self.index]));
        ret.* = trb.*;

        self.index += 1;
        if (self.index == self.trbs.len - 1) {
            self.rotate();
        }

        return ret;
    }

    /// Push a Link TRB and reset the cursor.
    fn rotate(_: *Ring) void {
        urd.unimplemented("Ring.rotate");
    }

    /// Deinitialize the Ring and free the backing memory.
    pub fn deinit(self: *Ring, allocator: PageAllocator) void {
        allocator.free(self.trbs);
        self.trbs = undefined;
    }
};

/// Event Ring used by the xHC to pass command completion and async events to software.
pub const EventRing = struct {
    /// Number of Event Ring Segment.
    ///
    /// Supports only one ERS for now.
    const num_ers = 1;

    /// Buffers for TRB.
    trbs: []volatile Trb,
    /// Consumer Cycle State.
    ccs: u1 = 1,
    /// Dequeue index into TRBs.
    dequeue: usize = 0,
    /// Event Ring Segment Table.
    erst: []ErstEntry,
    /// Interrupter module.
    interrupter: regs.Interrupter,

    /// Initialize a new Event Ring.
    pub fn new(irs: regs.Interrupter, allocator: PageAllocator) mem.Error!EventRing {
        const buf = try allocator.alloc(Trb, trbs_per_page);
        errdefer allocator.free(buf);
        for (buf) |*e| e.* = std.mem.zeroes(Trb);

        const erst = try allocator.alloc(ErstEntry, num_ers);
        return .{
            .trbs = buf,
            .dequeue = 0,
            .erst = erst,
            .interrupter = irs,
        };
    }

    /// Initialize and set the Event Ring to the primary interrupter.
    pub fn init(self: *EventRing) void {
        rtt.expectEqual(self.erst.len, self.trbs.len / trbs_per_page);

        // Initialize ERST entries.
        for (self.erst, 0..) |*erst, i| {
            const start = i * trbs_per_page;
            erst.* = .from(self.trbs[start .. start + trbs_per_page]);
        }

        // Set the Event Ring Segment Table.
        const erst_phys = mem.page.translateIntP(self.erst.ptr);
        self.interrupter.write(regs.Erstsz, @as(u32, @intCast(self.erst.len)));
        self.interrupter.write(regs.Erstba, erst_phys);
        self.interrupter.modify(regs.Erdp, .{
            .erdp = toErdpPhys(self.trbs),
        });

        // Set the CCS to 1.
        self.ccs = 1;
    }

    /// Check if an event is queued in the Event Ring.
    pub fn hasEvent(self: *const EventRing) bool {
        return self.trbs[self.dequeue].cycle == self.ccs;
    }

    /// Get the next event TRB if exists and advance the dequeue pointer.
    pub fn next(self: *EventRing) ?*volatile Trb {
        if (!self.hasEvent()) {
            return null;
        }
        const trb = &self.trbs[self.dequeue];

        self.dequeue += 1;
        if (self.dequeue == self.trbs.len) {
            self.dequeue = 0;
            self.ccs +%= 1;
        }

        self.interrupter.modify(regs.Erdp, .{
            .erdp = toErdpPhys(&self.trbs[self.dequeue]),
        });

        return trb;
    }
};

/// Entry in ERST (Event Ring Segment Table).
///
/// ERST is used to define multi-segment Event Rings,
/// which enables runtime expansion and shrinking of the Event Ring.
const ErstEntry = packed struct(u128) {
    /// Base address of the Event Ring Segment.
    ring_segment_base: u64,
    /// Number of TRBs in the Event Ring Segment.
    size: u16,
    /// Reserved.
    _82: u48 = 0,

    pub fn from(ring: []volatile Trb) ErstEntry {
        return .{
            .ring_segment_base = mem.page.translateIntP(ring.ptr),
            .size = @intCast(ring.len),
        };
    }
};

// =============================================================
// Utility
// =============================================================

/// Convert a pointer to the u60 ERDP field value.
inline fn toErdpPhys(virt: anytype) u60 {
    return @truncate(mem.page.translateIntP(virt) >> @bitOffsetOf(regs.Erdp, "erdp"));
}

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

const regs = @import("registers.zig");
const trbs = @import("trb.zig");
const Trb = trbs.Trb;
