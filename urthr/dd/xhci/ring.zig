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
        for (buf) |*e| e.* = std.mem.zeroes(Trb);

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
    fn rotate(_: *Ring) void {
        urd.unimplemented("Ring.rotate");
    }

    /// Deinitialize the Ring and free the backing memory.
    pub fn deinit(self: *Ring, allocator: PageAllocator) void {
        allocator.free(self.trbs);
        self.trbs = undefined;
    }
};

/// Event Ring that is used by the xHC to pass command completion and async events to software.
pub const EventRing = struct {
    /// Number of Event Ring Segment.
    ///
    /// Supports only one ERS for now.
    const num_ers = 1;
    /// Number of TRBs per Event Ring Segment.
    const num_trbs_per_segment = mem.page_size / @sizeOf(Trb);

    /// Buffers for TRB.
    trbs: []volatile Trb,
    /// Producer Cycle State.
    pcs: u1 = 1,
    /// Event Ring Segment Table.
    erst: []ErstEntry,
    /// Interrupter module.
    interrupter: regs.Interrupter,

    /// Initialize a new Event Ring.
    pub fn new(irs: regs.Interrupter, allocator: PageAllocator) mem.Error!EventRing {
        const buf = try allocator.alloc(Trb, num_trbs_per_segment);
        errdefer allocator.free(buf);
        for (buf) |*e| e.* = std.mem.zeroes(Trb);

        const erst = try allocator.alloc(ErstEntry, num_ers);
        return .{
            .trbs = buf,
            .erst = erst,
            .interrupter = irs,
        };
    }

    /// Initialize and set the Event Ring to the primary interrupter.
    pub fn init(self: *EventRing) void {
        rtt.expectEqual(self.erst.len, self.trbs.len / num_trbs_per_segment);

        // Initialize ERST entries.
        for (self.erst, 0..) |*erst, i| {
            erst.* = .from(self.trbs[i * num_trbs_per_segment .. (i + 1) * num_trbs_per_segment]);
        }

        // Set the Event Ring Segment Table.
        const erst_phys = mem.page.translateIntP(self.erst.ptr);
        self.interrupter.write(regs.Erstsz, @as(u32, @intCast(self.erst.len)));
        self.interrupter.write(regs.Erstba, erst_phys);
        self.interrupter.modify(regs.Erdp, .{
            .erdp = @as(u60, @truncate(mem.page.translateIntP(self.trbs.ptr) >> @bitOffsetOf(regs.Erdp, "erdp"))),
        });

        // Set the PCS to 1.
        self.pcs = 1;
    }

    /// Check if more than one event is queued in the Event Ring.
    pub fn hasEvent(self: *const EventRing) bool {
        return self.poke().cycle == self.pcs;
    }

    /// Get the TRB pointed to by the Interrupter's dequeue pointer.
    pub fn poke(self: *const EventRing) *volatile Trb {
        const erdp = self.interrupter.read(regs.Erdp);
        return @ptrFromInt(mem.page.translateInt(erdp.erdp << @bitOffsetOf(regs.Erdp, "erdp")));
    }

    /// Get the next event TRB if exists and increment the dequeue pointer.
    pub fn next(self: *EventRing) ?*volatile Trb {
        const trb = self.poke();
        if (trb.cycle != self.pcs) {
            return null;
        }

        const next_trb: *volatile Trb = if (@intFromPtr(trb) >= @intFromPtr(&self.trbs[self.trbs.len - 1])) blk: {
            self.pcs = !self.pcs;
            break :blk &self.trbs[0];
        } else @ptrFromInt(@intFromPtr(trb) + @sizeOf(Trb));

        self.interrupter.modify(regs.Erdp, .{
            .erdp = mem.page.translateIntP(next_trb) >> @bitOffsetOf(regs.Erdp, "erdp"),
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
