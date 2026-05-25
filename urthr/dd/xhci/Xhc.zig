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

/// DCBAA.
///
/// Device Context pointed to by DCBAA entry is owned by the xHC.
/// Software must not modify them.
dcbaa: Dcbaa,

/// Command Ring.
cring: rings.Ring,
/// Event Ring.
ering: rings.EventRing,

/// xHC PCI class code.
const class = pci.ClassCode{
    .base = 0x0C,
    .sub = 0x03,
    .interface = 0x30,
};

/// Initialize the PCI device as an xHC controller.
pub fn initPci(hc: pci.Host, addr: pci.DevAddr) Error!*Self {
    const io = hc.getTypedIo(addr, pci.HeaderType0);

    // Check if it's an xHCI controller.
    {
        const rc = io.readReg(pci.HeaderRevClass);
        const cls = pci.ClassCode{
            .base = rc.base_class,
            .sub = rc.sub_class,
            .interface = rc.prog_if,
        };
        if (!std.meta.eql(class, cls)) {
            return Error.InvalidDevice;
        }
    }

    // Configure device command register.
    io.modifyReg(pci.HeaderCommandStatus, .{
        .memory_space_enable = true,
        .bus_master_enable = true,
    });

    // Check if BAR is valid.
    var barbuf: [1]pci.BarInfo = undefined;
    const bar = blk: {
        const bars = io.parseBars(&barbuf);
        if (bars.len != barbuf.len) {
            return Error.InvalidDevice;
        }
        if (bars[0].index != 0) {
            return Error.InvalidDevice;
        }
        if (bars[0].type != .mem64) {
            return Error.InvalidDevice;
        }

        break :blk bars[0];
    };

    // Configure BAR.
    const base, const phys = blk: {
        const phys_base = if (bar.address == 0)
            0x1000_0000 // TODO: assign appropriate free AXI address depending on board.
        else
            bar.address & bar.address_mask;

        const base = try mem.phys.reserveAndRemap(
            "xhc",
            phys_base,
            bar.size(),
            null,
            .device,
        );
        io.setBarAddress(bar, phys_base);

        break :blk .{ base, phys_base };
    };
    log.debug("xHC: BAR#{}: 0x{X} (size=0x{X}) -> 0x{X}", .{ bar.index, phys, bar.size(), base });

    return initMmio(base);
}

/// Initialize the xHC controller mapped to the given base address.
pub fn initMmio(base: usize) Error!*Self {
    const self = try mem.bin.create(Self);
    errdefer mem.bin.destroy(self);

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
    }
    log.debug("xHC capability register  @ 0x{X}", .{self.capability.base});
    log.debug("xHC operational register @ 0x{X}", .{self.operational.base});
    log.debug("xHC runtime register     @ 0x{X}", .{self.runtime.base});
    log.debug("xHC version              : 0x{X}", .{self.capability.read(regs.CapInfo).hci_version});
    log.debug("xHC max slots            : {}", .{self.capability.read(regs.StructureParam1).maxslots});
    log.debug("xHC max ports            : {}", .{self.capability.read(regs.StructureParam1).maxports});

    // Initialize DCBAA.
    self.dcbaa = try Dcbaa.init();

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

    for (0..max_ports) |i| {
        const port = self.getPortRegAt(i);

        if (!port.read(regs.PortSc).ccs) {
            continue;
        }

        // TODO: initialize device.
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
    const pr_size = 16;
    const base = self.operational.getMarkerAddress(.port_set) + index * pr_size;
    return .new(base);
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
