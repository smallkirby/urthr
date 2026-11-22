//! AMD IOMMU.
//!
//! ref. AMD I/O Virtualization Technology (IOMMU) Specification, 48882-PUB—Rev 3.11—Apr 2026

const Self = @This();

const Vi = mmio.Module(.{ .natural = u64 }, .{
    Reg(0x0000, TableBase),
    Reg(0x0018, Control),
    Reg(0x0030, Efr),
    Reg(0x2020, Status),
});

/// Register module.
vi: Vi,

/// Device table.
dt: DmaMemory,

/// Managed DMA allocator.
allocator: DmaAllocator,

pub const Error = common.mem.Error;

/// Create a new AMD-Vi instance.
pub fn new(base: usize, allocator: DmaAllocator) Self {
    return .{
        .vi = .new(base),
        .dt = undefined,
        .allocator = allocator,
    };
}

/// Initialize IOMMU with all devices passed through.
pub fn init(self: *Self) Error!void {
    // Allocate device table pages.
    self.dt = try self.allocator.alloc(DevTableEntry, num_dt_ents, .normal);
    @memset(self.dt.slice(DevTableEntry), std.mem.zeroes(DevTableEntry));
    self.allocator.syncForDeviceAll(self.dt);

    // Set the address of cleared device table.
    self.vi.write(TableBase, .init(self.dt.bus, self.dt.size));
}

// =============================================================
// Device Table
// =============================================================

/// DeviceID derived from Peripheral RequesterID.
pub const DeviceId = u16;

/// The number of device table entries in a table.
const num_dt_ents = std.math.pow(usize, 2, @bitSizeOf(DeviceId));

/// Device Table Entry.
const DevTableEntry = packed struct(u256) {
    /// Rest of this entry is valid.
    v: bool,
    /// Translation information valid.
    tv: bool,
    /// Reserved.
    _2: u2 = 0,
    /// CXL IO bits in ATS completions for CXL devices that implement the .cache interface.
    cxl_mem_attr: u3,
    /// Host Access Dirty.
    had: Had,
    /// Paging mode.
    mode: PagingMode,
    /// System physical address of the root page table for the I/O device for GPA-to-SPA translation.
    pgtbl_root: u40,
    /// PPR enable.
    ppr: bool,
    /// Guest PPR response with PASID.
    gprp: bool,
    /// Guest I/O protection valid.
    giov: bool,
    /// Guest translation valid.
    gv: bool,
    /// Guest levels translated.
    glx: u2,
    /// Guest CR3 table root pointer.
    gcr3trp: u3,
    /// I/O read permission.
    ir: bool,
    /// I/O write permission.
    iw: bool,
    /// Reserved.
    _63: u1 = 0,

    /// DomainID.
    /// 16-bit integer chosen by SW that the IOMMU must use to tag its internal translation caches and mark event log entries.
    domainid: u16,
    /// GCR3 Table Root Pointer.
    gcr3tbl_root_lo: u16,
    /// IOTLB enable.
    i: bool,
    /// Suppress I/O page fault events.
    se: bool,
    /// Suppress all I/O page fault events.
    sa: bool,
    /// Port I/O control.
    ioctl: u2,
    /// IOTLB cache hint.
    cache: bool,
    /// Snoop disable.
    sd: bool,
    /// Allow exclusion.
    ex: bool,
    /// System management message enable.
    sysmgt: u2,
    /// Secure ATS.
    sats: bool,
    /// GCR3 Table Root Pointer [51:31].
    gcr3tbl_root_hi: u21,

    /// Interrupt map valid.
    iv: bool,
    /// Interrupt table length.
    int_tab_len: u4,
    /// Ignore unmapped interrupts.
    ig: bool,
    /// Interrupt table root pointer.
    int_tab_root: u46,
    /// Reserved.
    _180: u2 = 0,
    /// Guest paging mode.
    gpmode: u2,
    /// INIT pass-through.
    init_pass: bool,
    /// ExtInt pass-through.
    eint_pass: bool,
    /// NMI pass-through.
    nmi_pass: bool,
    /// Host Page Table Mode Hint.
    hpt_mode: u1,
    /// Interrupt control.
    int_ctl: u2,
    /// LINT0 pass-through.
    lint0pass: bool,
    /// LINT1 pass-through.
    lint1pass: bool,

    /// Reserved.
    _192: u15 = 0,
    /// Virtualize IOMMU enabled.
    vimu_en: bool,
    /// Guest DeviceID.
    gdeviceid: u16,
    /// GuestID.
    guestid: u16,
    /// Reserved.
    _240: u5 = 0,
    /// Reserved.
    _245: u1 = 0,
    /// Attribute override valid.
    attrv: bool,
    ///
    mode0fc: bool,
    ///
    snoop_attr: u8,
};

/// Host Access Dirty.
const Had = enum(u2) {
    /// IOMMU does not set Access and Dirty bits in the host page table.
    none = 0b00,
    /// IOMMU sets Access bits in the host page table corresponding to peripheral requests.
    access = 0b01,
    /// IOMMU sets Access and Dirty bits in the host page table corresponding to peripheral requests.
    access_dirty = 0b11,
};

/// How IOMMU performs GPA-to-SPA translation.
const PagingMode = enum(u3) {
    /// Translation disabled.
    disable = 0b000,
    /// 1 Level Page Table (21-bit GPA)
    @"1" = 0b001,
    /// 2 Level Page Table (30-bit GPA)
    @"2" = 0b010,
    /// 3 Level Page Table (39-bit GPA)
    @"3" = 0b011,
    /// 4 Level Page Table (48-bit GPA)
    @"4" = 0b100,
    /// 5 Level Page Table (57-bit GPA)
    @"5" = 0b101,
    /// 6 Level Page Table (64-bit GPA)
    @"6" = 0b110,
};

// =============================================================
// Registers
// =============================================================

// =============================================================
// Control and Status Registers

/// Device Table Base Address Register.
const TableBase = packed struct(u64) {
    /// Size of the Device Table. The size is `(n + 1) * 4` Kbytes.
    size: u9,
    /// Reserved.
    _9: u3 = 0,
    /// Device Table base address. Bits [51:12] of the 4-Kbyte aligned base address of the first table.
    dev_tab_base: u40,
    /// Reserved.
    _52: u12 = 0,

    /// Create a table base register value.
    ///
    /// `phys` is the bus address of the first table.
    /// `size` is a size in bytes of the device table.
    pub fn init(phys: usize, size: usize) TableBase {
        rtt.expectEqual(0, phys % 4096);
        rtt.expectEqual(0, size % 4096);
        return .{
            .size = @intCast(size / 4096 - 1),
            .dev_tab_base = @truncate(phys >> 12),
        };
    }
};

/// IOMMU Control Register.
const Control = packed struct(u64) {
    /// IOMMU enable.
    en: bool,
    /// HyperTransport tunnel translation enable.
    ht_tun_en: bool,
    /// Event log enable.
    event_log_en: bool,
    /// Event log interrupt enable.
    event_int_en: bool,
    /// Completion wait interrupt enable.
    com_wait_int_en: bool,
    /// Invalidation timeout for IOTLB invalidation requests.
    inv_timeout: InvTimeout,
    /// Pass posted write.
    pass_pw: bool,
    /// Response pass posted write.
    res_pass_pw: bool,
    /// Coherent.
    coherent: bool,
    /// Isochronous.
    isoc: bool,
    /// Command buffer enable.
    cmd_buf_en: bool,
    /// Peripheral page request log enable.
    ppr_log_en: bool,
    /// Peripheral page request interrupt enable.
    ppr_int_en: bool,
    /// Peripheral page request enable.
    ppr_en: bool,
    /// Guest translation enable.
    gt_en: bool,
    /// Guest virtual APIC enable.
    ga_en: bool,
    /// Not used.
    crw: u4,
    /// SMI filter enable.
    smi_fen: enum(u1) { pass = 0, filter = 1 },
    /// Self writeback disable.
    slf_wb_dis: bool,
    /// SMI filter log enable.
    smi_flog_en: bool,
    /// Guest virtual APIC mode enabled.
    gam_en: Gam,
    /// Guest virtual APIC GA Log enable.
    ga_log_en: bool,
    /// Guest virtual APIC interrupt enable.
    ga_int_en: bool,
    /// Dual peripheral page request log enable.
    dual_ppr_log_en: DualLogMode,

    /// Dual event log enable.
    dual_event_log_en: DualLogMode,
    /// Device Table segmentation enable.
    dev_tbl_seg_en: DevTblSeg,
    /// Privilege abort mode.
    priv_abrt_en: u2,
    /// Peripheral Page Request automatic response feature enable.
    ppr_auto_rsp_en: bool,
    /// Memory address routing and control feature enable.
    marc_en: bool,
    /// Block StopMark messages feature enable.
    blk_stop_mrk_en: bool,
    /// PPR auto response Always On feature enable.
    ppr_auto_resp_aon: bool,
    /// Controls remapping behavior for MSI interrupts.
    num_int_remap_mode: IntRemapMode,
    /// Enhanced PPR handling.
    epe_en: bool,
    /// Access and Dirty bit update in host page table.
    had_update: u2,
    /// Disable hardware updating dirty bit in guest page table.
    gd_update_dis: bool,
    /// Reserved.
    _49: u1 = 0,
    /// Enable X2APIC.
    xt_en: bool,
    /// Enable IOMMU x2APIC interrupts generation.
    int_cap_xt_en: bool,
    /// Enable virtualized command buffer processing.
    vcmd_en: bool,
    /// Enable virtualized IOMMU.
    viommu_en: bool,
    /// Disable hardware update access bit in guest page table.
    ga_update_dis: bool,
    /// Guest APIC Physical Processor Interrupt enable.
    ga_ppi_en: bool,
    /// Enable support for Tiered Memory Page Migration Support inside IOMMU.
    tmpm_en: bool,
    /// Reserved.
    _57: u1 = 0,
    /// GCR3TRPMode.
    gcr3trp_mode: bool,
    /// Disable IRTE caching.
    irt_cache_dis: bool,
    /// Controls how IOMMU computes the Base pointer of the vIOMMU accelerated Guest Buffers.
    gst_buffer_trp_mode: bool,
    /// Controls guest virtual APIC mode when the system is SNP-enabled.
    snpavic_en: u3,

    /// Guest virtual APIC mode.
    const Gam = enum(u3) {
        int_remap = 0b000,
        vint_remap = 0b001,
    };
};

/// IOMMU invalidate timeout.
const InvTimeout = enum(u3) {
    no = 0b000,
    @"1ms" = 0b001,
    @"10ms" = 0b010,
    @"100ms" = 0b011,
    @"1sec" = 0b100,
    @"10sec" = 0b101,
    @"100sec" = 0b110,
};

/// Device Table segmentation mode.
const DevTblSeg = enum(u3) {
    none = 0b000,
    @"2" = 0b001,
    @"4" = 0b010,
    @"8" = 0b011,
};

const IntRemapMode = enum(u2) {
    /// Remap up to 512 interrupts per function.
    @"512" = 0b00,
    /// Remap up to 2048 interrupts per function.
    @"2048" = 0b01,
};

const DualLogMode = enum(u2) {
    default = 0b00,
    alternate = 0b01,
    auto = 0b10,
};

/// IOMMU Extended Feature Register.
const Efr = packed struct(u64) {
    /// Prefetch support.
    pre_fsup: bool,
    /// Peripheral page request support.
    ppr_sup: bool,
    /// x2APIC support.
    xt_sup: bool,
    /// EXE (PMR) and PRIV supported.
    nx_sup: bool,
    /// Guest translations supported.
    gt_sup: bool,
    /// Guest APIC Physical Processor Interrupt Support.
    gappi_sup: bool,
    /// INVALIDATE_IOMMU_ALL supported.
    ia_sup: bool,
    /// Guest Virtual APIC Support.
    ga_sup: bool,
    /// Hardware Error registers supported.
    he_sup: bool,
    /// Performance counters supported.
    pc_sup: bool,
    /// Host Address Translation Size.
    hats: AtSize,
    /// Guest Address Translation Size.
    gats: AtSize,
    /// Guest CR3 root table level supported.
    glx_sup: Glx,
    /// SMI filter register supported.
    smif_sup: u2,
    /// SMI filter register count.
    smi_frc: u3,
    /// Guest virtual APIC modes supported.
    gam_sup: u3,
    /// Dual PPR log support.
    dual_ppr_log_sup: DualLogMode,
    /// Reserved.
    _26: u2 = 0,
    /// Dual Event Log Support.
    dual_event_log_sup: DualLogMode,
    /// Reserved.
    _30: u1 = 0,
    /// Secure ATS support.
    sats_sup: bool,

    /// Maximum PASID supported. Bit width - 1.
    pas_max: u5,
    /// User / Supervisor page protection feature supported.
    us_sup: bool,
    /// Segmented Device Table feature support.
    dev_tbl_seg_sup: u2,
    /// PPR Log Overflow Early Warning Support.
    ppr_earlyof_sup: bool,
    /// PPR Automatic Response Support.
    ppr_auto_resp_sup: bool,
    /// Memory Access Routing and Control feature support.
    marc_sup: u2,
    /// Block StopMark messages feature Support.
    blk_stop_mrk_sup: bool,
    /// IOMMU performance optimization feature.
    perf_opt_sup: bool,
    /// MSI Capability Register MMIO access Support.
    msi_cap_mmio_sup: bool,
    /// HW supports returning memory attributes of the guest page to ATS requester along with ATS completion.
    snoop_attrs_sup: bool,
    /// Guest I/O Protection Support.
    gio_sup: bool,
    /// Host Access Support.
    ha_sup: bool,
    /// Enhanced PPR Handling Support.
    eph_sup: bool,
    /// Attribute Forward Support.
    attr_fw_sup: bool,
    /// Host Dirty Support.
    hd_sup: bool,
    /// HW supports disabling v2 Dirty bit updates by HW.
    v2hd_dis_sup: bool,
    /// Invalidate IOTLB Type Support.
    inv_iotlb_type_sup: bool,
    /// Virtualized IOMMU support.
    viommu_sup: bool,
    /// SEV support by HW.
    vm_guard_io_sup: bool,
    /// Reserved.
    _57: u4 = 0,
    /// Disabling v2 access bit updates by HW.
    v2had_dis_sup: bool,
    /// Force Physical Destination Mode for Remapped Interrupt Support.
    force_phy_dest_sup: bool,
    /// Secure Nested Paging support.
    snp_sup: bool,
};

/// Address translation size.
const AtSize = enum(u2) {
    /// 4 levels.
    @"4" = 0b00,
    /// 5 levels.
    @"5" = 0b01,
    /// 6 levels.
    @"6" = 0b10,
};

/// Guest CR3 root table level.
const Glx = enum(u2) {
    single = 0b00,
    two = 0b01,
    three = 0b10,
};

// =============================================================
// Command and Event Status Register

/// IOMMU Status Register.
const Status = packed struct(u64) {
    /// Event log overflow. RW1C.
    event_overflow: bool,
    /// Event log interrupt. RW1C.
    event_log_int: bool,
    /// Completion wait interrupt. RW1C.
    com_wait_int: bool,
    /// Event logging is running.
    event_log_run: bool,
    /// Command buffer is running.
    cmd_buf_run: bool,
    /// PPR log overflow. RW1C.
    ppr_overflow: bool,
    /// PPR interrupt. RW1C.
    ppr_int: bool,
    /// PPR logging is running.
    ppr_log_run: bool,
    /// Guest virtual APIC logging is running.
    ga_log_run: bool,
    /// Guest virtual APIC log overflow. RW1C.
    gal_overflow: bool,
    /// Guest virtual APIC log interrupt. RW1C.
    ga_int: bool,
    /// PPR Log B has overflowed.
    ppr_overflow_b: bool,
    /// PPR Log A is active.
    ppr_log_active: bool,
    /// Reserved.
    _13: u2 = 0,
    /// Event Log B has overflowed. RW1C.
    event_overflow_b: bool,
    /// Event Log A is active.
    event_log_active: bool,
    /// PPR log B Overflow Early warning. RW1C.
    ppr_overflow_early_b: bool,
    /// PPR log Overflow Early warning. RW1C.
    ppr_overflow_early: bool,
    /// Reserved.
    _19: u45 = 0,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.amdvi);
const common = @import("common");
const rtt = common.rtt;
const mmio = common.io.mmio;
const Reg = common.io.Reg;
const DmaAllocator = common.mem.DmaAllocator;
const DmaMemory = DmaAllocator.DmaMemory;
