//! Extensible Host Controller.

const Self = @This();

pub const Error = error{
    /// The device is not an xHC controller.
    InvalidDevice,
} || mem.Error;

/// xHC PCI class code.
const class = pci.ClassCode{
    .base = 0x0C,
    .sub = 0x03,
    .interface = 0x30,
};

/// Initialize the PCI device as an xHC controller.
pub fn init(hc: pci.Host, addr: pci.DevAddr) Error!*Self {
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

    // TODO: unimplemented
    urd.unimplemented("Xhc.init");
}

// =============================================================
// Registers
// =============================================================

/// xHCI Capability Registers.
const Capability = packed struct {
    /// Offset from register base to the Operational Register Space.
    cap_length: u8,
    /// Reserved
    _8: u8 = 0,
    /// BCD encoding of the xHCI spec revision number supported by this HC.
    hci_version: u16,
    /// HC Structural Parameters 1.
    hcs_params1: StructureParam1,
    /// HC Structural Parameters 2.
    hcs_params2: u32,
    /// HC Structural Parameters 3.
    hcs_params3: u32,
    /// HC Capability Parameters 1.
    hcc_params1: CapParam1,
    /// Doorbell Array Offset.
    dboff: u32,
    /// Runtime Register Space Offset.
    rtsoff: u32,
    /// HC Capability Parameters 2.
    hcc_params2: u32,
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

/// HCCPARAMS1
const CapParam1 = packed struct(u32) {
    /// Unimplemented
    _0: u16 = 0,
    /// xHCI Extended Capabilities Pointer.
    xecp: u16,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.xhc);
const Allocator = std.mem.Allocator;
const common = @import("common");
const rtt = common.rtt;
const dd = @import("dd");
const pci = dd.pci;
const urd = @import("urthr");
const mem = urd.mem;
