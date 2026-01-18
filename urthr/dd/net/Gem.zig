//! Cadence Gigabit Ethernet MAC (GEM_GXL 1p09)

// =============================================================
// Module Definition
// =============================================================

const gem = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x0000, Ncr },
    .{ 0x0004, Ncfgr },
    .{ 0x0008, Nsr },
    .{ 0x0034, Man },
});

const Self = @This();

/// MMIO register module.
module: gem,

/// Create a new GEM instance.
pub fn new(base: usize) Self {
    var module = gem{};
    module.setBase(base);

    return .{
        .module = module,
    };
}

/// Initialize PHY and GEM controller.
pub fn init(self: *Self) void {
    // Enable MDIO.
    self.module.write(Ncr, std.mem.zeroInit(Ncr, .{
        .mpe = true,
    }));
    self.module.modify(Ncfgr, .{
        .clk = 6, // div by 128
    });
    self.module.modify(Nsr, .{
        .idle = true,
    });

    // Check PHY ID.
    log.info("PHY ID: {X:0>4}-{X:0>4}", .{
        self.mdioRead(2),
        self.mdioRead(3),
    });
    if (self.mdioRead(2) == 0xFFFF or self.mdioRead(3) == 0xFFFF) {
        @panic("No PHY detected.");
    }

    // Software reset.
    self.mdioWrite(0, 0x8000);

    // Wait for reset to complete.
    var timer = arch.timer.createTimer();
    timer.start(.sec(1));
    while (self.mdioRead(0) & 0x8000 != 0) {
        if (timer.expired()) {
            @panic("PHY reset timed out.");
        }
        std.atomic.spinLoopHint();
    }
}

// =============================================================
// MDIO
// =============================================================

/// PHY address.
const phy_addr = 1;

/// Read a PHY register at a specific PHY address.
fn mdioReadAddr(self: *Self, phy: u5, reg: u5) u16 {
    self.mdioWaitForIdle();

    self.module.write(Man, Man{
        .sof = 0b01, // Clause 22
        .rw = .read,
        .phya = phy,
        .rega = reg,
        .code = 0b10,
        .data = 0,
    });

    self.mdioWaitForIdle();

    return self.module.read(Man).data;
}

/// Read a PHY register.
fn mdioRead(self: *Self, reg: u5) u16 {
    return self.mdioReadAddr(phy_addr, reg);
}

/// Write to a PHY register.
fn mdioWrite(self: *Self, reg: u5, value: u16) void {
    self.mdioWaitForIdle();

    self.module.write(Man, Man{
        .sof = 0b01, // Clause 22
        .rw = .write,
        .phya = phy_addr,
        .rega = reg,
        .code = 0b10,
        .data = value,
    });

    self.mdioWaitForIdle();
}

/// Wait for the MDIO operation to complete.
fn mdioWaitForIdle(self: *Self) void {
    var timer = arch.timer.createTimer();
    timer.start(.ms(10));

    while (self.module.read(Nsr).idle == false) {
        if (timer.expired()) {
            @panic("GEM MDIO operation timed out.");
        }

        std.atomic.spinLoopHint();
    }
}

// =============================================================
// Registers
// =============================================================

/// Network Control Register.
const Ncr = packed struct(u32) {
    /// Reserved.
    lb: u1 = 0,
    /// Loop back local.
    llb: bool,
    /// Receive enable.
    re: bool,
    /// Transmit enable.
    te: bool,
    /// Management port enable.
    mpe: bool,
    /// Clear stats.
    clrstat: bool,
    /// Incremental stats.
    incstat: bool,
    /// Write enable stats.
    westat: bool,
    /// Back pressure.
    bp: bool,
    /// Start transmission.
    tstart: bool,
    /// Transmit halt.
    thalt: bool,
    /// Transmit pause frame.
    tpf: bool,
    /// Transmit zero quantum pause frame.
    tzq: bool,
    /// Reserved.
    _0: u2 = 0,
    /// Store Receive Timestamp to Memory.
    srtsm: bool,
    /// Reserved.
    _1: u4 = 0,
    /// PTP Unicast packet enable.
    ptpuni: bool,
    /// Reserved.
    _2: u3 = 0,
    /// Enable One Step Synchro Mode.
    ossmode: bool,
    /// Reserved.
    _3: u3 = 0,
    /// MII Usage on RGMII Interface.
    miionrgmii: bool,
    /// Reserved.
    _4: u2 = 0,
    ///
    enable_hs_mac: bool,
};

/// Network Configuration Register.
const Ncfgr = packed struct(u32) {
    /// Speed.
    spd: bool,
    /// Full duplex.
    fd: bool,
    /// Discard non-VLAN frames.
    bit_rate: bool,
    /// Reserved.
    jframe: bool,
    /// Copy all frames.
    caf: bool,
    /// No broadcast.
    nbc: bool,
    /// Multicast hash enable.
    mti: bool,
    /// Unicast hash enable.
    uni: bool,
    /// Receive 1536 byte frames.
    big: bool,
    /// External address match enable.
    eae: bool,
    ///
    _0: u2 = 0,
    /// Retry test.
    rty: bool,
    /// Pause enable.
    pae: bool,
    /// Receive buffer offset
    rbof: u2,
    /// Length field error frame discard.
    rlce: bool,
    /// FCS remove.
    drfcs: bool,
    /// MDC clock division.
    clk: u3,
    ///
    _1: u11 = 0,
};

/// Network Status Register.
const Nsr = packed struct(u32) {
    /// pcs_link_state.
    link: bool,
    /// Status of the mdio_in pin.
    mdio: bool,
    /// The PHY management logic is idle.
    idle: bool,
    /// Reserved.
    _0: u29 = 0,
};

/// PHY Maintenance Register.
const Man = packed struct(u32) {
    /// Data.
    data: u16,
    /// Code.
    code: u2,
    /// Register address.
    rega: u5,
    /// PHY address.
    phya: u5,
    /// Operation.
    rw: enum(u2) {
        /// Read.
        read = 2,
        /// Write.
        write = 1,
    },
    /// Start of frame.
    sof: u2,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.gem);
const common = @import("common");
const mmio = common.mmio;
const Timer = common.Timer;
const arch = @import("arch").impl;
