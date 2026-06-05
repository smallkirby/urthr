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
    /// DMA memory backing the TRB ring.
    memory: DmaMemory,
    /// Number of TRBs in the ring.
    size: usize,

    /// Producer Cycle State.
    pcs: u1 = 1,
    /// Next index to write to.
    index: usize = 0,
    /// DMA allocator that manages the memory.
    allocator: DmaAllocator,

    /// Initialize a new Ring.
    pub fn new(size: usize, allocator: DmaAllocator) mem.Error!Ring {
        const memory = try allocator.allocBytes(@sizeOf(Trb) * size, .normal);
        errdefer allocator.freeBytes(memory);
        @memset(memory.slice(u8), 0);

        // Initialize Link TRB at the end of the buffer.
        memory.slice(Trb)[size - 1] = @bitCast(std.mem.zeroInit(trbs.LinkTrb, .{
            .ringp = memory.bus,
            .intr_target = 0,
            .cycle = 1,
            .tc = true,
            .chain = false,
            .ioc = false,
        }));
        allocator.syncForDevice(memory.cpu, memory.size);

        return .{
            .memory = memory,
            .size = size,
            .allocator = allocator,
        };
    }

    /// Enqueue a TRB to the Ring.
    ///
    /// The TRB is synced for device access.
    pub fn push(self: *Ring, value: *Trb) *const Trb {
        var trb = value;
        trb.cycle = self.pcs;

        const slice = self.memory.slice(Trb);
        const index = self.index;
        slice[index] = trb.*;
        self.allocator.syncForDeviceAny(&slice[index]);

        self.index += 1;
        if (self.index == self.size - 1) {
            self.rotate();
        }

        return &slice[index];
    }

    /// Push a Link TRB and reset the cursor.
    fn rotate(_: *Ring) void {
        urd.unimplemented("Ring.rotate");
    }

    /// Deinitialize the Ring and free the backing memory.
    pub fn deinit(self: *Ring) void {
        self.allocator.freeBytes(self.memory);
        self.memory = undefined;
    }
};

/// Event Ring used by the xHC to pass command completion and async events to software.
pub const EventRing = struct {
    /// Number of Event Ring Segment.
    ///
    /// Supports only one ERS for now.
    const num_ers = 1;

    /// Buffers for TRB.
    trbs: DmaMemory,
    /// Consumer Cycle State.
    ccs: u1 = 1,
    /// Dequeue index into TRBs.
    dequeue: usize = 0,
    /// Event Ring Segment Table.
    erst: DmaMemory,
    /// Interrupter module.
    interrupter: regs.Interrupter,
    /// DMA allocator that manages the memory.
    allocator: DmaAllocator,

    /// Initialize a new Event Ring.
    pub fn new(irs: regs.Interrupter, allocator: DmaAllocator) mem.Error!EventRing {
        const memory = try allocator.allocBytes(@sizeOf(Trb) * trbs_per_page, .normal);
        errdefer allocator.freeBytes(memory);
        @memset(memory.slice(u8), 0);

        const erst = try allocator.allocBytes(@sizeOf(ErstEntry) * num_ers, .normal);
        return .{
            .trbs = memory,
            .dequeue = 0,
            .erst = erst,
            .interrupter = irs,
            .allocator = allocator,
        };
    }

    /// Initialize and set the Event Ring to the primary interrupter.
    pub fn init(self: *EventRing) void {
        // Initialize ERST entries.
        for (self.erst.slice(ErstEntry), 0..) |*erst, i| erst.* = .{
            .ring_segment_base = self.trbs.bus + i * trbs_per_page * @sizeOf(Trb),
            .size = trbs_per_page,
        };

        self.allocator.syncForDevice(self.erst.cpu, self.erst.size);
        self.allocator.syncForDevice(self.trbs.cpu, self.trbs.size);

        // Set the Event Ring Segment Table.
        self.interrupter.write(regs.Erstsz, @as(u32, @intCast(self.erst.slice(ErstEntry).len)));
        self.interrupter.write(regs.Erstba, self.erst.bus);
        self.interrupter.modify(regs.Erdp, .{
            .erdp = toErdpBus(self.trbs.bus),
        });

        // Set the CCS to 1.
        self.ccs = 1;
    }

    /// Check if an event is queued in the Event Ring.
    pub fn hasEvent(self: *const EventRing) bool {
        self.allocator.syncForCpu(
            self.trbs.cpu + self.dequeue * @sizeOf(Trb),
            @sizeOf(Trb),
        );
        return self.trbs.slice(Trb)[self.dequeue].cycle == self.ccs;
    }

    /// Get the next event TRB if exists and advance the dequeue pointer.
    pub fn next(self: *EventRing) ?*volatile Trb {
        if (!self.hasEvent()) {
            return null;
        }
        const trb = &self.trbs.slice(Trb)[self.dequeue];

        self.dequeue += 1;
        if (self.dequeue == self.trbs.slice(Trb).len) {
            self.dequeue = 0;
            self.ccs +%= 1;
        }

        self.interrupter.modify(regs.Erdp, .{
            .erdp = toErdpBus(self.trbs.bus + self.dequeue * @sizeOf(Trb)),
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
};

// =============================================================
// Utility
// =============================================================

/// Convert a bus address to the u60 ERDP field value.
inline fn toErdpBus(bus: usize) u60 {
    return @truncate(bus >> @bitOffsetOf(regs.Erdp, "erdp"));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.xhc);
const common = @import("common");
const DmaAllocator = common.mem.DmaAllocator;
const DmaMemory = DmaAllocator.DmaMemory;
const rtt = common.rtt;
const urd = @import("urthr");
const mem = urd.mem;

const regs = @import("registers.zig");
const trbs = @import("trb.zig");
const Trb = trbs.Trb;
