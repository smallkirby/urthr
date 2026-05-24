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
    self.* = std.mem.zeroes(Self);

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

    // TODO
}

// =============================================================
// Internals
// =============================================================

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

/// Get the address of Interrupter Register Set (IRS) at the given index.
fn getIrsAt(self: *Self, index: usize) regs.Interrupter {
    const rt_size = 32;
    const irs_size = 32;
    const addr = self.runtime.base + rt_size + index * irs_size;
    return .new(addr);
}

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
