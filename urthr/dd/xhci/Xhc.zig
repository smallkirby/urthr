//! Extensible Host Controller.

const Self = @This();

pub const Error = error{
    /// The device is not an xHC controller.
    InvalidDevice,
    /// Controller is in an invalid state for the requested operation.
    InvalidState,
} || mem.Error;

/// Capability registers module.
capability: Capability,
/// Operational registers module.
operational: Operational,
/// Runtime registers module.
runtime: Runtime,

/// xHC PCI class code.
const class = pci.ClassCode{
    .base = 0x0C,
    .sub = 0x03,
    .interface = 0x30,
};

/// Initialize the PCI device as an xHC controller.
pub fn initPci(hc: pci.Host, addr: pci.DevAddr) Error!*Self {
    const io = hc.getTypedIo(addr, pci.HeaderType0);

    const self = try mem.bin.create(Self);
    errdefer mem.bin.destroy(self);
    self.* = std.mem.zeroes(Self);

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
        const cap_info = self.capability.read(CapInfo);
        self.operational.setBase(base + cap_info.cap_length);

        // Runtime registers.
        const rts_off = self.capability.read(RtsOffset).value;
        self.runtime.setBase(base + rts_off & ~@as(u64, 0x1F));
    }
    log.debug("xHC capability register  @ 0x{X}", .{self.capability.base});
    log.debug("xHC operational register @ 0x{X}", .{self.operational.base});
    log.debug("xHC runtime register     @ 0x{X}", .{self.runtime.base});
    log.debug("xHC version              : 0x{X}", .{self.capability.read(CapInfo).hci_version});
    log.debug("xHC max slots            : {}", .{self.capability.read(StructureParam1).maxslots});
    log.debug("xHC max ports            : {}", .{self.capability.read(StructureParam1).maxports});

    return self;
}

/// Reset the controller.
pub fn reset(self: *Self) Error!void {
    // Stop xHC.
    self.operational.modify(CommandRegister, .{
        .inte = false,
        .hsee = false,
        .ewe = false,
        .rs = false,
    });

    // Wait until xHC stops.
    while (self.operational.read(StatusRegister).hch == false) {
        std.atomic.spinLoopHint();
    }

    // Reset xHC.
    self.operational.modify(CommandRegister, .{
        .hc_rst = true,
    });

    // Wait until reset is complete.
    while (self.operational.read(CommandRegister).hc_rst) {
        std.atomic.spinLoopHint();
    }

    // Wait until the controller is ready.
    while (self.operational.read(StatusRegister).cnr) {
        std.atomic.spinLoopHint();
    }
}

// =============================================================
// Registers
// =============================================================

// =============================================================
// xHCI Capability Registers

const Capability = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, CapInfo },
    .{ 0x04, StructureParam1 },
    .{ 0x08, StructureParam2 },
    .{ 0x0C, StructureParam3 },
    .{ 0x10, CapParam1 },
    .{ 0x14, DbOffset },
    .{ 0x18, RtsOffset },
    .{ 0x1C, CapParam2 },
});

const CapInfo = packed struct(u32) {
    /// Offset from register base to the Operational Register Space.
    cap_length: u8,
    /// Reserved
    _8: u8 = 0,
    /// BCD encoding of the xHCI spec revision number supported by this HC.
    hci_version: u16,
};

/// HCSPARAMS1
const StructureParam1 = packed struct(u32) {
    /// Number of device slots.
    maxslots: u8,
    /// Number of interrupters.
    maxintrs: u11,
    /// Reserved.
    _19: u5 = 0,
    /// Number of ports.
    maxports: u8,
};

const StructureParam2 = packed struct(u32) {
    value: u32,
};

const StructureParam3 = packed struct(u32) {
    value: u32,
};

/// HCCPARAMS1
const CapParam1 = packed struct(u32) {
    /// Unimplemented
    _0: u16 = 0,
    /// xHCI Extended Capabilities Pointer.
    xecp: u16,
};

const DbOffset = packed struct(u32) {
    value: u32,
};

const RtsOffset = packed struct(u32) {
    value: u32,
};

const CapParam2 = packed struct(u32) {
    value: u32,
};

// =============================================================
// xHC Operational Registers

const Operational = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, CommandRegister },
    .{ 0x04, StatusRegister },
    .{ 0x08, PageSize },
    .{ 0x50, ConfigureRegister },
    .{ 0x400, mmio.Marker(.port_set) },
});

const PageSize = packed struct(u32) {
    value: u32,
};

/// USB Status Register. (USBSTS)
const StatusRegister = packed struct(u32) {
    /// HCHalted.
    hch: bool,
    /// Reserved.
    _1: u1 = 0,
    /// Host System Error.
    hse: bool,
    /// Event Interrupt.
    eint: bool,
    /// Port Change Detect.
    pcd: bool,
    /// Reserved.
    _5: u3 = 0,
    /// Save State Status.
    sss: bool,
    /// Restore State Status.
    rss: bool,
    /// Save/Restore Error.
    sre: bool,
    /// Controller Not Ready.
    cnr: bool,
    /// Host Controller Error.
    hce: bool,
    /// Reserved.
    _13: u19 = 0,
};

/// Runtime xHC configuration register. (CONFIG)
const ConfigureRegister = packed struct(u32) {
    /// Number of Device Slots Enabled.
    max_slots_en: u8,
    /// U3 Entry Enable.
    u3e: bool,
    /// Configuration Information Enable.
    cie: bool,
    /// Reserved.
    _10: u22 = 0,
};

/// USB Command Register. (USBCMD)
const CommandRegister = packed struct(u32) {
    /// Run/Stop.
    /// When set to 1, the xHC proceeds with execution of the schedule.
    /// When set to 0, the xHC completes the current transaction and halts.
    rs: bool,
    /// Host Controller Reset.
    hc_rst: bool,
    /// Interrupt Enable.
    inte: bool,
    /// Host System Error Enable,
    hsee: bool,
    /// Reserved
    _4: u3 = 0,
    /// Light Host Controller Reset.
    lhcrst: bool,
    /// Controller Save State.
    css: bool,
    /// Controller Restore State.
    crs: bool,
    /// Enable Wrap Event.
    ewe: bool,
    /// Enable U3 MFINDEX Stop.
    u3s: bool,
    /// Reserved.
    _12: u1 = 0,
    /// CEM Enable.
    cme: bool,
    /// Extended TBC Enable.
    ete: bool,
    /// Extended TBC TRB Status Enable.
    tsc_en: bool,
    /// VTIO Enable.
    vtioe: bool,
    /// Reserved.
    _17: u15 = 0,
};

// =============================================================
// xHCI Runtime Registers

const Runtime = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, MfIndex },
});

const MfIndex = packed struct(u32) {
    value: u32,
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
