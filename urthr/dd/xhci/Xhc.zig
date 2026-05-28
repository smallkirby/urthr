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
cring: rings.Ring,
/// Event Ring.
ering: rings.EventRing,

/// List of registered devices.
devices: DeviceList = .empty,

/// Initialization complete and ready to handle events.
ready: bool = false,

/// xHC PCI class code.
pub const class = pci.ClassCode{
    .base = 0x0C,
    .sub = 0x03,
    .interface = 0x30,
};

/// List of registered devices.
const DeviceList = std.ArrayList(*Device);

/// Initialize the xHC controller mapped to the given base address.
pub fn init(base: usize, irq: urd.exception.Vector) (Error || urd.exception.Error)!*Self {
    const self = try mem.bin.create(Self);
    errdefer mem.bin.destroy(self);
    self.* = std.mem.zeroInit(Self, .{});

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

    // Initialize DCBAA.
    self.dcbaa = try Dcbaa.init();

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

    for (1..max_ports) |i| {
        const port = self.getPortRegAt(i);

        if (!port.read(regs.PortSc).ccs) {
            continue;
        }
        log.info("Port#{d}: Connected device detected.", .{i});

        // Register the found device.
        const device = try Device.new(i, port);
        try self.devices.append(urd.mem.bin, device);

        // Reset the port to initialize the device.
        device.resetPort();
    }
}

// =============================================================
// Internals
// =============================================================

/// Initialize Command Ring and Event Ring.
fn initRings(self: *Self) Error!void {
    // Init Command Ring.
    self.cring = try rings.Ring.new(rings.trbs_per_page, mem.page);
    self.operational.write(regs.Crcr0, regs.Crcr0{
        .rcs = self.cring.pcs,
        .cs = false,
        .ca = false,
        .crp = @truncate(mem.page.translateIntP(self.cring.trbs) >> @bitOffsetOf(regs.Crcr0, "crp")),
    });
    self.operational.write(regs.Crcr1, regs.Crcr1{
        .crp = @truncate(mem.page.translateIntP(self.cring.trbs) >> 32),
    });

    // Init Event Ring for the primary Interrupter.
    const irs0 = self.getIrsAt(0);
    self.ering = try rings.EventRing.new(irs0, mem.page);
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
            else => log.err("Unsupported event type: {d}", .{@intFromEnum(event.type)}),
        }
    }
}

/// Handle Port Status Change event.
fn handlePortStatusChange(self: *Self, event: *const volatile trbs.PortStatusChange) Error!void {
    // Check if the event is for a registered port.
    const device = self.findDeviceByPort(event.port) orelse {
        log.warn("Port Status Change event for unregistered port: {d}", .{event.port});
        return Error.NotAvailable;
    };
    rtt.expectEqual(.success, event.code);

    const psc = device.pr.read(regs.PortSc);
    if (psc.prc) {
        // Port Reset Change.
        log.info("Port#{d}: Reset completed.", .{event.port});

        // Push Enable Slot TRB to Command Ring.
        var enable_slot = trbs.EnableSlotTrb{ .cycle = undefined };
        _ = self.cring.push(.from(&enable_slot));

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

// =============================================================
// Data structures
// =============================================================

/// Device Context Base Address Array.
const Dcbaa = struct {
    /// Virtual pointer to DCBAA.
    _raw: *RawDcbaa,

    const RawDcbaa = extern struct {
        /// Physical pointers to device contexts.
        entries: [std.math.maxInt(u8)]usize,

        comptime {
            urd.comptimeAssert(@sizeOf(@This()) == 2040, "Invalid DCBAA size: {d}", .{@sizeOf(@This())});
        }
    };

    /// Get the physical address of the DCBAA.
    pub fn dcbaap(self: *const Dcbaa) usize {
        return mem.page.translateIntP(self._raw);
    }

    /// Initialize DCBAA at the given memory.
    pub fn init() mem.Error!Dcbaa {
        const page = try mem.page.allocPagesV(1);
        const raw: *RawDcbaa = @ptrCast(page.ptr);
        const storage: [*]u8 = @ptrCast(raw);

        @memset(storage[0..@sizeOf(RawDcbaa)], 0);

        return .{ ._raw = raw };
    }

    /// Deinitialize DCBAA.
    pub fn deinit(self: *Dcbaa) void {
        const ptr: [*]const u8 = @ptrCast(self._raw);
        mem.page.freePages(ptr[0..mem.size_4kib]);
    }

    /// Set the Device Context for the given slot index.
    pub fn set(self: *const Dcbaa, slot: u8, context: usize) void {
        self._raw.entries[slot] = mem.page.translateIntV(context);
    }

    /// Get the pointer to the Device Context of the given slot index.
    pub fn at(self: *const Dcbaa, slot: u8) ?usize {
        const ret = self._raw.entries[slot];
        return if (ret == 0) null else mem.page.translateIntV(ret);
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
const dd = @import("dd");
const pci = dd.pci;
const urd = @import("urthr");
const mem = urd.mem;

const regs = @import("registers.zig");
const rings = @import("ring.zig");
const trbs = @import("trb.zig");
const Trb = trbs.Trb;
const Device = @import("Device.zig");
