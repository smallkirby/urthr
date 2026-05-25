// =============================================================
// xHCI Capability Registers

pub const Capability = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, CapInfo },
    .{ 0x04, StructureParam1 },
    .{ 0x08, StructureParam2 },
    .{ 0x0C, StructureParam3 },
    .{ 0x10, CapParam1 },
    .{ 0x14, DbOffset },
    .{ 0x18, RtsOffset },
    .{ 0x1C, CapParam2 },
});

pub const CapInfo = packed struct(u32) {
    /// Offset from register base to the Operational Register Space.
    cap_length: u8,
    /// Reserved
    _8: u8 = 0,
    /// BCD encoding of the xHCI spec revision number supported by this HC.
    hci_version: u16,
};

/// HCSPARAMS1
pub const StructureParam1 = packed struct(u32) {
    /// Number of device slots.
    maxslots: u8,
    /// Number of interrupters.
    maxintrs: u11,
    /// Reserved.
    _19: u5 = 0,
    /// Number of ports.
    maxports: u8,
};

pub const StructureParam2 = packed struct(u32) {
    value: u32,
};

pub const StructureParam3 = packed struct(u32) {
    value: u32,
};

/// HCCPARAMS1
pub const CapParam1 = packed struct(u32) {
    /// Unimplemented
    _0: u16 = 0,
    /// xHCI Extended Capabilities Pointer.
    xecp: u16,
};

pub const DbOffset = packed struct(u32) {
    value: u32,
};

pub const RtsOffset = packed struct(u32) {
    value: u32,
};

pub const CapParam2 = packed struct(u32) {
    value: u32,
};

// =============================================================
// xHC Operational Registers

pub const Operational = mmio.Module(.{ .natural = u64 }, &.{
    .{ 0x00, CommandRegister },
    .{ 0x04, StatusRegister },
    .{ 0x08, PageSize },
    .{ 0x18, Crcr0 },
    .{ 0x1C, Crcr1 },
    .{ 0x48, Dcbaap },
    .{ 0x50, ConfigureRegister },
    .{ 0x400, mmio.Marker(.port_set) },
});

/// USB Command Register. (USBCMD)
pub const CommandRegister = packed struct(u32) {
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

/// USB Status Register. (USBSTS)
pub const StatusRegister = packed struct(u32) {
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

pub const PageSize = packed struct(u32) {
    value: u32,
};

/// Lower 32 bits of Command Ring Control Register.
pub const Crcr0 = packed struct(u32) {
    /// Ring Cycle State.
    ///
    /// Indicates the xHC Consumer Cycle State (CCS).
    /// Write is ignored if CRR is set.
    rcs: u1,
    /// Command Stop.
    ///
    /// Writing 1 shall stop the operation of the Command Ring after the completion of the currently executing command.
    cs: bool,
    /// Command Abort.
    ///
    /// Writing 1 shall immediately terminate the currently executing command.
    ca: bool,
    /// Command Ring Running. (read-only)
    crr: bool = undefined,
    /// Reserved.
    _4: u2 = 0,
    /// Command Ring Pointer, lower 32 bits.
    crp: u26,
};

/// Upper 32 bits of Command Ring Control Register.
pub const Crcr1 = packed struct(u32) {
    /// Command Ring Pointer, upper 32 bits.
    crp: u32,
};

/// Device Context Base Address Array Pointer.
pub const Dcbaap = packed struct(u64) {
    value: u64,
};

/// Runtime xHC configuration register. (CONFIG)
pub const ConfigureRegister = packed struct(u32) {
    /// Number of Device Slots Enabled.
    max_slots_en: u8,
    /// U3 Entry Enable.
    u3e: bool,
    /// Configuration Information Enable.
    cie: bool,
    /// Reserved.
    _10: u22 = 0,
};

/// Entry in Port Register Set.
pub const Port = mmio.Module(.{ .natural = u64 }, &.{
    .{ 0x00, PortSc },
    .{ 0x04, PortPmsc },
    .{ 0x08, PortLi },
    .{ 0x0C, PortHlpmc },
});

/// Port Status and Control Register.
pub const PortSc = packed struct(u32) {
    /// Current Connect Status.
    ///
    /// If true, the port is connected to a device.
    ccs: bool,
    /// Port Enabled/Disabled.
    ped: bool,
    /// Reserved.
    _2: u1 = 0,
    /// Over-current Active.
    oca: bool,
    /// Port Reset.
    pr: bool,
    /// Port Link State.
    pls: u4,
    /// Port Power.
    pp: bool,
    /// Port Speed.
    speed: PortSpeed,
    /// Port Indicator Control.
    pic: u2,
    /// Port Link State Write Strobe.
    lws: bool,
    /// Connect Status Change. RW1CS.
    csc: bool,
    /// Port Enabled/Disabled Change.
    pec: bool,
    /// Warm Port Reset Change.
    wrc: bool,
    /// Over-current Change.
    occ: bool,
    /// Port Reset Change.
    prc: bool,
    /// Port Link State Change.
    plc: bool,
    /// Port Config Error Change.
    cec: bool,
    /// Cold Attach Status.
    cas: bool,
    /// Wake on Connect Enable.
    wce: bool,
    /// Wake on Disconnect Enable.
    wde: bool,
    /// Wake on Over-current Enable.
    woe: bool,
    /// Reserved.
    _28: u2 = 0,
    /// Device Removable.
    dr: bool,
    /// Warm Port Reset.
    wpr: bool,
};

const PortSpeed = enum(u4) {
    invalid = 0,
    full = 1,
    low = 2,
    high = 3,
    super = 4,
    super_plus = 5,

    pub fn maxPacketSize(self: PortSpeed) u16 {
        return switch (self) {
            .invalid => 0,
            .full => 8,
            .low => 8,
            .high => 64,
            .super => 512,
            .super_plus => 512,
        };
    }
};

/// Port Power Management Status and Control Register.
pub const PortPmsc = packed struct(u32) {
    value: u32,
};

/// Port Link Info Register.
pub const PortLi = packed struct(u32) {
    value: u32,
};

/// Port Hardware LPM Control Register.
pub const PortHlpmc = packed struct(u32) {
    value: u32,
};

// =============================================================
// xHCI Runtime Registers

pub const Runtime = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, MfIndex },
});

pub const MfIndex = packed struct(u32) {
    value: u32,
};

// =============================================================
// Interrupter Register

/// Interrupter Register for each interrupter.
pub const Interrupter = mmio.Module(.{ .natural = u64 }, &.{
    .{ 0x00, Iman },
    .{ 0x04, Imod },
    .{ 0x08, Erstsz },
    .{ 0x10, Erstba },
    .{ 0x18, Erdp },
});

/// Interrupt Management Register.
pub const Iman = packed struct(u32) {
    /// Interrupt Pending (IP). RW1C.
    ip: bool,
    /// Interrupt Enable (IE)
    ie: bool,
    /// Reserved.
    _2: u30,
};

/// Interrupt Moderation Register.
pub const Imod = packed struct(u32) {
    /// Interrupter Moderation Interval, in 250ns increments (IMODI).
    imodi: u16,
    /// Reserved.
    _reserved: u16,
};

/// Event Ring Segment Table Size Register.
pub const Erstsz = packed struct(u32) {
    value: u32,
};

/// Event Ring Segment Table Base Address Register.
pub const Erstba = packed struct(u64) {
    value: u64,
};

/// Event Ring Dequeue Pointer Register.
pub const Erdp = packed struct(u64) {
    /// Dequeue ERST Segment Index. May be used by xHC.
    desi: u3,
    /// EHB. RW1C.
    ehb: u1,
    /// High 60 bits of current Event Ring Dequeue Pointer.
    erdp: u60,
};

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const mmio = common.mmio;
