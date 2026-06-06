//! Extensible Host Controller.

const Self = @This();

pub const Error = error{
    /// The device is not an xHC controller.
    InvalidDevice,
    /// Controller is in an invalid state for the requested operation.
    InvalidState,
} || mem.Error;

/// Capability registers module.
capability: regs.Capability,
/// Operational registers module.
operational: regs.Operational,
/// Runtime registers module.
runtime: regs.Runtime,
/// Doorbell registers array.
dbs: DoorBellArray,

/// DCBAA.
///
/// Device Context pointed to by DCBAA entry is owned by the xHC.
/// Software must not modify them.
dcbaa: Dcbaa = undefined,

/// Command Ring.
cring: rings.Ring = undefined,
/// Event Ring.
ering: rings.EventRing = undefined,

/// Context size in bytes.
csz: enum { @"32", @"64" } = .@"32",

/// List of registered devices.
devices: DeviceList = .empty,

/// Initialization complete and ready to handle events.
ready: bool = false,
/// DMA allocator.
dma: DmaAllocator,

/// xHC PCI class code.
pub const class = pci.ClassCode{
    .base = 0x0C,
    .sub = 0x03,
    .interface = 0x30,
};

/// List of registered devices.
const DeviceList = std.ArrayList(*Device);

/// Initialize the xHC controller mapped to the given base address.
pub fn init(base: usize, irq: urd.exception.Vector, dma: DmaAllocator) (Error || urd.exception.Error)!*Self {
    const self = try mem.bin.create(Self);
    errdefer mem.bin.destroy(self);
    @memset(std.mem.asBytes(self), 0);
    self.dma = dma;

    // Initialize registers.
    {
        // Capability registers.
        self.capability.setBase(base + 0);

        // Operational registers.
        const cap_info = self.capability.read(regs.CapInfo);
        self.operational.setBase(base + cap_info.cap_length);

        // Runtime registers.
        const rts_off = self.capability.read(regs.RtsOffset).value;
        self.runtime.setBase(base + (rts_off & ~@as(u64, 0x1F)));

        // Doorbell registers.
        const db_base = self.capability.read(regs.DbOffset).value;
        self.dbs = DoorBellArray.new(base + db_base);
    }
    log.debug("xHC capability register  @ 0x{X}", .{self.capability.base});
    log.debug("xHC operational register @ 0x{X}", .{self.operational.base});
    log.debug("xHC runtime register     @ 0x{X}", .{self.runtime.base});
    log.debug("xHC doorbell register    @ 0x{X}", .{self.dbs.base});
    log.debug("xHC version              : 0x{X}", .{self.capability.read(regs.CapInfo).hci_version});
    log.debug("xHC max slots            : {}", .{self.capability.read(regs.StructureParam1).maxslots});
    log.debug("xHC max ports            : {}", .{self.capability.read(regs.StructureParam1).maxports});
    log.debug("xHC context size         : {d} bytes", .{@as(u8, if (self.capability.read(regs.CapParam1).csz) 64 else 32)});

    // Initialize DCBAA.
    self.dcbaa = try Dcbaa.init(dma);

    // Set context size.
    self.csz = if (self.capability.read(regs.CapParam1).csz) .@"64" else .@"32";

    // Register IRQ handler.
    try self.registerController(irq);

    return self;
}

/// Reset the controller.
pub fn reset(self: *Self) Error!void {
    // Stop xHC.
    self.operational.modify(regs.CommandRegister, .{
        .inte = false,
        .hsee = false,
        .ewe = false,
        .rs = false,
    });

    // Wait until xHC stops.
    while (self.operational.read(regs.StatusRegister).hch == false) {
        std.atomic.spinLoopHint();
    }

    // Reset xHC.
    self.operational.modify(regs.CommandRegister, .{
        .hc_rst = true,
    });

    // Wait until reset is complete.
    while (self.operational.read(regs.CommandRegister).hc_rst) {
        std.atomic.spinLoopHint();
    }

    // Wait until the controller is ready.
    while (self.operational.read(regs.StatusRegister).cnr) {
        std.atomic.spinLoopHint();
    }
}

/// Setup necessary internal structure.
pub fn setup(self: *Self) Error!void {
    // Set max device slots.
    self.operational.modify(regs.ConfigureRegister, .{
        .max_slots_en = self.capability.read(regs.StructureParam1).maxslots,
    });

    // Initialize scratchpad buffers if required.
    const sp2 = self.capability.read(regs.StructureParam2);
    const num_sp: usize = @as(usize, sp2.max_scratchpad_hi) << 5 | sp2.max_scratchpad_lo;
    if (num_sp > 0) {
        try self.initScratchpad(num_sp);
    }

    // Initialize rings.
    try self.initRings();
    // Enable  interrupts.
    try self.enableInterrupt();
    // Set DCBAA pointer.
    self.operational.write(regs.Dcbaap, self.dcbaa.dcbaap());

    {
        const irs0 = self.getIrsAt(0);
        log.debug("xHC Primary Interrupter Register Set:", .{});
        log.debug("  ERSTSZ: 0x{X}", .{@as(u32, @bitCast(irs0.read(regs.Erstsz)))});
        log.debug("  ERSTBA: 0x{X}", .{@as(u64, @bitCast(irs0.read(regs.Erstba)))});
        log.debug("  ERDP:   0x{X}", .{@as(u64, @bitCast(irs0.read(regs.Erdp)))});
    }

    self.ready = true;
}

/// Start the controller.
pub fn run(self: *Self) void {
    self.operational.modify(regs.CommandRegister, .{
        .rs = true,
    });

    self.operational.waitFor(regs.StatusRegister, .{
        .hch = false,
    }, null);
}

/// Scan all ports.
pub fn scan(self: *Self) mem.Error!void {
    const max_ports = self.capability.read(regs.StructureParam1).maxports;

    for (1..max_ports + 1) |i| {
        const port = self.getPortRegAt(i);

        if (!port.read(regs.PortSc).ccs) {
            continue;
        }
        log.info("Port#{d}: Connected device detected.", .{i});

        // Register the found device.
        const device = try Device.new(self, i, port);
        try self.devices.append(urd.mem.bin, device);

        // Reset the port to initialize the device.
        device.resetPort();
    }
}

// =============================================================
// Internals
// =============================================================

/// Set the Device Context bus address in DCBAA for the given slot index.
pub fn setDeviceContext(self: *const Self, slot: u8, region: usize) void {
    rtt.expect(slot != 0);
    self.dcbaa.set(slot, region);
}

/// Allocate scratchpad buffers and register them in DCBAA[0].
fn initScratchpad(self: *Self, num: usize) Error!void {
    const page_size: usize = @as(usize, 1) << (@ctz(self.operational.read(regs.PageSize).value) + 12);

    // Allocate Scratchpad Buffer Array.
    const arr = try self.dma.allocBytes(num * @sizeOf(u64), .normal);
    @memset(arr.slice(u8), 0);

    // Allocate Scratchpad Buffers and set their bus addresses in the array.
    for (arr.slice(u64)[0..num]) |*entry| {
        const buf = try self.dma.allocBytes(page_size, .normal);
        @memset(buf.slice(u8), 0);
        self.dma.syncForDevice(buf.cpu, page_size);
        entry.* = buf.bus;
    }
    self.dma.syncForDevice(arr.cpu, num * @sizeOf(u64));

    self.dcbaa.set(0, arr.bus);
}

/// Initialize Command Ring and Event Ring.
fn initRings(self: *Self) Error!void {
    // Init Command Ring.
    self.cring = try rings.Ring.new(rings.trbs_per_page, self.dma);
    self.operational.write(regs.Crcr0, regs.Crcr0{
        .rcs = self.cring.pcs,
        .cs = false,
        .ca = false,
        .crp = @truncate(self.cring.memory.bus >> @bitOffsetOf(regs.Crcr0, "crp")),
    });
    self.operational.write(regs.Crcr1, regs.Crcr1{
        .crp = @truncate(self.cring.memory.bus >> 32),
    });

    // Init Event Ring for the primary Interrupter.
    const irs0 = self.getIrsAt(0);
    self.ering = try rings.EventRing.new(irs0, self.dma);
    self.ering.init();
}

/// Enable interrupts for the primary Interrupter.
fn enableInterrupt(self: *Self) Error!void {
    const irs0 = self.getIrsAt(0);

    irs0.modify(regs.Imod, .{
        .imodi = 4000, // 250ns * 4000 = 1ms
    });
    irs0.modify(regs.Iman, .{
        .ie = true,
        .ip = true,
    });
    self.operational.modify(regs.CommandRegister, .{
        .inte = true,
    });
}

/// Get the address of Interrupter Register Set (IRS) at the given index.
fn getIrsAt(self: *Self, index: usize) regs.Interrupter {
    const rt_size = 32;
    const irs_size = 32;
    const addr = self.runtime.base + rt_size + index * irs_size;
    return .new(addr);
}

/// Get the Port Register at the given index.
fn getPortRegAt(self: *Self, index: usize) regs.Port {
    rtt.expect(index != 0);

    const pr_size = 16;
    const base = self.operational.getMarkerAddress(.port_set) + (index - 1) * pr_size;
    return .new(base);
}

/// Find the registered device associated with the given port index.
fn findDeviceByPort(self: *Self, port: usize) ?*Device {
    for (self.devices.items) |device| {
        if (device.pi == port) {
            return device;
        }
    } else return null;
}

/// Find the registered device associated with the given slot index.
fn findDeviceBySlot(self: *Self, slot: u8) ?*Device {
    for (self.devices.items) |device| {
        if (device.slot == slot) {
            return device;
        }
    } else return null;
}

/// Find the registered device associated with the given pending TRB.
///
/// Clears the pending TRB of the found device.
fn findDeviceByTrb(self: *Self, trb: *const volatile trbs.Trb) ?*Device {
    for (self.devices.items) |device| {
        if (device.pending_trb == trb) {
            device.pending_trb = null;
            return device;
        }
    } else return null;
}

// =============================================================
// IRQ
// =============================================================

/// List of registered controllers.
var controllers: [3]?IrqController = [_]?IrqController{null} ** 3;

const IrqController = struct {
    /// Controller instance.
    controller: *Self,
    /// Exception vector associated with this controller.
    irq: urd.exception.Vector,
};

/// Register the controller to handle the given IRQ.
fn registerController(self: *Self, irq: urd.exception.Vector) (Error || urd.exception.Error)!void {
    for (controllers, 0..) |e, i| if (e == null) {
        controllers[i] = IrqController{
            .controller = self,
            .irq = irq,
        };
        try urd.exception.setHandler(irq, irqHandler);

        return;
    };
    unreachable;
}

/// IRQ handler.
fn irqHandler(vector: urd.exception.Vector) void {
    for (controllers) |c| if (c) |entry| {
        if (entry.irq == vector) {
            const self = entry.controller;
            if (!self.ready) return;

            // TODO: should not handle events in IRQ context.
            self.handleEvent() catch |err| {
                log.err("Failed to handle xHC event: {t}", .{err});
            };
        }
    };
}

/// Handles pending events in the Event Ring.
///
/// Dispatches the event to the appropriate handler based on the event type.
fn handleEvent(self: *Self) Error!void {
    while (self.ering.next()) |event| {
        switch (event.type) {
            .port_status_change => try self.handlePortStatusChange(@ptrCast(event)),
            .command_completion => try self.handleCommandCompletion(@ptrCast(event)),
            .transfer_event => try self.handleTransferEvent(@ptrCast(event)),

            else => log.err("Unsupported event type: {d}", .{@intFromEnum(event.type)}),
        }
    }
}

/// Handle Port Status Change event.
fn handlePortStatusChange(self: *Self, event: *const volatile trbs.PortStatusChange) Error!void {
    // Check if the event is for a registered port.
    const device = self.findDeviceByPort(event.port) orelse {
        return;
    };
    rtt.expectEqual(.success, event.code);

    const psc = device.pr.read(regs.PortSc);
    if (psc.prc) {
        // Port Reset Change.
        log.info("Port#{d}: Reset completed.", .{event.port});

        // Push Enable Slot TRB to Command Ring.
        var enable_slot = trbs.EnableSlotTrb{ .cycle = undefined };
        device.pending_trb = self.cring.push(.from(&enable_slot));

        // Notify xHC of the new command.
        self.dbs.notifyCommand();
    } else if (psc.csc) {
        // Connect Status Change.
        if (psc.ccs) {
            // Hot plug.
            urd.unimplemented("xHC device hot plug.");
        } else {
            // Unplug.
            urd.unimplemented("xHC device unplug.");
        }
    }
}

/// Handles Command Completion event.
///
/// This dispatches the command completion event to the appropriate handler based on the command type.
fn handleCommandCompletion(self: *Self, event: *const volatile trbs.CommandCompletionTrb) Error!void {
    const command_trb = event.commandTrb(self.cring.memory);
    const command_type = command_trb.type;
    const slot_id = event.slot_id;

    switch (command_type) {
        // Slot ID is assigned.
        .enable_slot => {
            const device = findDeviceByTrb(self, @ptrCast(command_trb)) orelse {
                log.warn("Enable Slot Completion event for unregistered device: {d}", .{@intFromEnum(command_type)});
                return Error.NotAvailable;
            };
            if (event.code != .success) {
                log.err("Port#{d}: Enable Slot failed: {t}", .{ device.pi, event.code });
                return Error.InvalidState;
            }
            log.debug("Port#{d}:Slot#{d}: Slot enabled.", .{ device.pi, slot_id });

            try device.assignAddress(slot_id);
        },

        // Address assigned and Device Context is set.
        .address_device => {
            const device = findDeviceByTrb(self, @ptrCast(command_trb)) orelse {
                log.warn("Address Device Completion event for unregistered device: {d}", .{@intFromEnum(command_type)});
                return Error.NotAvailable;
            };
            if (event.code != .success) {
                log.err("Port#{d}:Slot#{d}: Failed to assign address: {t}", .{ device.pi, slot_id, event.code });
                return Error.InvalidState;
            }
            log.debug("Port#{d}:Slot#{d}: Device addressed.", .{ device.pi, slot_id });

            try device.onAddressAssigned();
        },

        // Unhandled command completion.
        else => {
            log.warn("Unhandled command completion: {d}", .{@intFromEnum(command_type)});
        },
    }
}

/// Handles Transfer Event.
///
/// Delegates the event to the appropriate device based on the slot ID in the event.
fn handleTransferEvent(self: *Self, event: *const volatile trbs.TransferEventTrb) Error!void {
    const slot = event.slot_id;

    // Find the device by slot ID.
    const device = findDeviceBySlot(self, slot) orelse {
        log.warn("Transfer Event for unregistered slot: {d}", .{slot});
        return Error.NotAvailable;
    };

    // Dispatch to the device.
    try device.onTransferEvent(event);
}

// =============================================================
// Data structures
// =============================================================

/// Device Context Base Address Array.
const Dcbaa = struct {
    /// DMA memory backing the DCBAA.
    memory: DmaMemory,
    /// DMA allocator that manages the memory.
    dma: DmaAllocator,

    const RawDcbaa = extern struct {
        /// Bus address pointers to device contexts.
        entries: [std.math.maxInt(u8)]usize,

        comptime {
            urd.comptimeAssert(@sizeOf(@This()) == 2040, "Invalid DCBAA size: {d}", .{@sizeOf(@This())});
        }
    };

    /// Get the bus address of the DCBAA.
    pub fn dcbaap(self: *const Dcbaa) usize {
        return self.memory.bus;
    }

    /// Initialize DCBAA using the given DMA allocator.
    pub fn init(dma: DmaAllocator) DmaAllocator.Error!Dcbaa {
        const memory = try dma.allocBytes(@sizeOf(RawDcbaa), .normal);
        @memset(memory.slice(u8), 0);
        dma.syncForDevice(memory.cpu, @sizeOf(RawDcbaa));

        return .{
            .memory = memory,
            .dma = dma,
        };
    }

    /// Deinitialize DCBAA.
    pub fn deinit(self: *Dcbaa) void {
        self.dma.freeBytes(self.memory);
    }

    /// Set the Device Context bus address for the given slot index.
    pub fn set(self: *const Dcbaa, slot: u8, context: usize) void {
        const entry = &self.ptr().entries[slot];
        entry.* = context;
        self.dma.syncForDevice(@intFromPtr(entry), @sizeOf(usize));
    }

    fn ptr(self: *const Dcbaa) *RawDcbaa {
        return self.memory.as(RawDcbaa);
    }
};

/// Array of DB Registers.
const DoorBellArray = struct {
    /// Base address of DB registers array.
    base: usize,

    const T = mmio.Register(regs.DoorBell, u32);

    fn new(base: usize) DoorBellArray {
        return .{ .base = base };
    }

    /// Get the DB Register at the given index.
    fn at(self: *const DoorBellArray, index: usize) *volatile regs.DoorBell {
        return @ptrFromInt(self.base + index * @sizeOf(regs.DoorBell));
    }

    /// Notify the xHC of a command being pushed to the Command Ring.
    pub fn notifyCommand(self: *const DoorBellArray) void {
        const db = self.at(0);
        T.modify(@intFromPtr(db), .{
            .target = 0,
        });
    }

    /// Notify the specified endpoint, of the device specified by the slot ID, of a new TRB in the Transfer Ring.
    pub fn notifyEndpoint(self: *const DoorBellArray, slot: u8, dci: u5) void {
        const db = self.at(slot);
        T.modify(@intFromPtr(db), .{
            .target = dci,
        });
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.xhc);
const Allocator = std.mem.Allocator;
const arch = @import("arch").impl;
const common = @import("common");
const mmio = common.mmio;
const rtt = common.rtt;
const DmaAllocator = common.mem.DmaAllocator;
const DmaMemory = DmaAllocator.DmaMemory;
const dd = @import("dd");
const pci = dd.pci;
const urd = @import("urthr");
const mem = urd.mem;

const regs = @import("registers.zig");
const rings = @import("ring.zig");
const trbs = @import("trb.zig");
const Trb = trbs.Trb;
const Device = @import("Device.zig");
