/// System registers.
pub const SystemReg = enum {
    elr_el1,
    elr_el2,
    elr_el3,

    hcr_el2,

    daif,

    sp_el0,
    sp_el1,
    sp_el2,
    sp_el3,

    spsr_el1,
    spsr_el2,
    spsr_el3,

    vbar_el1,
    vbar_el2,
    vbar_el3,

    esr_el1,
    esr_el2,
    esr_el3,

    tcr_el2,
    tcr_el1,

    id_aa64mmfr0_el1,

    far_el1,
    far_el2,
    far_el3,
    pfar_el1,

    mair_el1,
    ttbr0_el1,
    ttbr1_el1,

    sctlr_el1,

    cntpct_el0,
    cntfrq_el0,

    /// Get the string representation of the system register.
    pub fn str(comptime self: SystemReg) []const u8 {
        return @tagName(self);
    }

    /// Get the type of the system register.
    pub fn Type(comptime self: SystemReg) type {
        return switch (self) {
            .elr_el1, .elr_el2, .elr_el3 => Elr,
            .hcr_el2 => HcrEl2,
            .daif => Daif,
            .sp_el0, .sp_el1, .sp_el2, .sp_el3 => Sp,
            .spsr_el1, .spsr_el2, .spsr_el3 => Spsr,
            .vbar_el1, .vbar_el2, .vbar_el3 => Vbar,
            .esr_el1, .esr_el2, .esr_el3 => Esr,
            .tcr_el2, .tcr_el1 => Tcr,
            .id_aa64mmfr0_el1 => IdAa64Mmfr0,
            .far_el1, .far_el2, .far_el3 => Far,
            .pfar_el1 => Pfar,
            .mair_el1 => Mair,
            .ttbr0_el1 => Ttbr0El1,
            .ttbr1_el1 => Ttbr1El1,
            .sctlr_el1 => SctlrEl1,
            .cntpct_el0 => Cntpct,
            .cntfrq_el0 => Cntfrq,
        };
    }
};

/// ELR_ELx.
///
/// Exception Link Register.
pub const Elr = packed struct(u64) {
    /// Return address.
    addr: u64,
};

/// SP_ELx.
pub const Sp = packed struct(u64) {
    /// Stack pointer.
    addr: u64,
};

/// HCR_EL2.
///
/// Hypervisor Configuration Register. Provides controls for virtualization.
pub const HcrEl2 = packed struct(u64) {
    /// Virtualization enable.
    vm: bool,
    /// Set/Way Invalidation Override.
    swio: bool,
    /// Protected Table Walk.
    ptw: bool,
    /// Physical FIQ Routing.
    fmo: bool,
    /// Physical IRQ Routing.
    imo: bool,
    /// Physical SError exception routing.
    amo: bool,
    /// Virtual FIQ Interrupt.
    vf: bool,
    /// Virtual IRQ Interrupt.
    vi: bool,

    /// Virtual SError exception.
    vse: bool,
    /// Force broadcast.
    fb: bool,
    /// Barried Shareability upgrade.
    bsu: u2,
    /// Default Cacheability.
    dc: bool,
    /// Traps EL0 and EL1 execution of WFI instructions to EL2, when EL2 is enabled in the current Security state.
    twi: bool,
    /// Traps EL0 and EL1 execution of WFE instruction to EL2, when EL2 is enabled in the current Security state.
    twe: bool,
    /// Reserved when Aarch32 is not supported.
    tid0: bool,

    /// Trap ID group 1.
    tid1: bool,
    /// Trap ID group 2.
    tid2: bool,
    /// Trap ID group 3.
    tid3: bool,
    /// Trap SMC instruction.
    tsc: bool,
    /// Trap IMPLEMENTATION DEFINED functionality.
    tidcp: bool,
    /// Trap Auciliary Control Registers.
    tacr: bool,
    /// Trap data or unified cache maintenance instructions that operate by Set/Way.
    tsw: bool,
    /// When FEAT_DPB is implemented, TPCP. Trap data or unified cache maintenance instructions that operate to the Point of Coherency or Persistence.
    /// Otherwise, TPC. Trap data or unified cache maintenance instructions that operate to the Point of Coherency.
    tpcp_tpc: bool,

    /// Trap cache maintenance instructions that operate to the Point of Unification.
    tpu: bool,
    /// Trap TLB maintenance instructions.
    ttlb: bool,
    /// Trap Virtual Memory controls.
    tvm: bool,
    /// Trap General Exceptions from EL0.
    tge: bool,
    /// Trap DC ZVA instructions.
    tdz: bool,
    /// Reserved when EL3 is implemented.
    hcd: bool,
    /// Trap Reads of Virtual Memory controls.
    trvm: bool,
    /// When EL1 is capable of using Aarch32, execution state control for lower Exception levels.
    /// When set, the Execution state for EL1 is Aarch64.
    rw: bool,

    /// Stage 2 Data access cacheability disable.
    cd: bool,
    /// Stage 2 Instruction access cacheability disable.
    id: bool,
    /// When FEAT_VHE is implemented, EL2 Host. Enables a configuration where a Host OS is running in EL2, and the Host OS's applications are running in EL0.
    /// Otherwise, reservd.
    e2h: bool,
    /// When FEAT_LOR is implemented, Trap LOR registers.
    /// Otherwise, reserved.
    tlor: bool,
    /// When FEAT_RAS is implemented, Trap accesses of Error Record registers.
    /// Otherwise, reserved.
    terr: bool,
    /// When FEAT_RAS is implemented, Route synchronous External abort exceptions to EL2.
    /// Otherwise, reserved.
    tea: bool,
    /// Mismatched Inner/Outer Cacheable Non-Coherency Enable for the EL1&0 translation regimes.
    miocnce: bool,
    /// When FEAT_TME is implemented, Enables access to the TSTART, TCOMMIT, TTEST, and TCANCEL instructions at EL0 and EL1.
    /// Otherwise, reserved.
    tme: bool,

    /// When FEAT_PAuth is implemented, Trap registers holding "key" values for PAuth.
    /// Otherwise, reserved.
    apk: bool,
    /// When FEAT_PAuth is implemented, Controls the use of instructions related to PAuth.
    /// Otherwise, reserved.
    api: bool,
    /// When FEAT_NV2 or FEAT_NV is implemented, Nested Virtualization.
    /// Otherwise, reserved.
    nv: bool,
    /// When FEAT_NV2 or FEAT_NV is implemented, Nested Virtualization.
    /// Otherwise, reserved.
    nv1: bool,
    /// When FEAT_NV is implemented, Address Translation.
    /// Otherwise, reserved.
    at: bool,
    /// When FEAT_NV2 is implemented, Nested Virtualization.
    /// Otherwise, reserved.
    nv2: bool,
    /// When FEAT_S2FWB is implemented, Forced Write-Back.
    /// Otherwise, reserved.
    fwb: bool,
    /// When FEAT_RASv1p1 is implemented, Fault Injection Enable.
    /// Otherwise, reserved.
    fien: bool,

    /// When FEAT_RME is implemented, Controls the reporting of Granule protection faults at EL0 and EL1.
    /// Otherwise, reserved.
    gpf: bool,
    /// When FEAT_EVT is implemented, Trap ID group 4.
    /// Otherwise, reserved.
    tid4: bool,
    /// When FEAT_EVT is implemented, Trap ICIALLUIS/IC IALLUIS cache maintenance instructions.
    /// Otherwise, reserved.
    ticab: bool,
    /// When FEAT_AMUv1p1 is implemented, Active Monitors Virtual Offsets Enable.
    /// Otherwise, reserved.
    amvoffen: bool,
    /// When FEAT_EVT is implemented, Trap cache maintenance instructions that operate to the Point of Unification.
    /// Otherwise, reserved.
    tocu: bool,
    /// When FEAT_CSV2_2 is implemented, Enable Access to the SCXTNUM_EL1 and SCXTNUM_EL0 registers.
    /// Otherwise, reserved.
    enscxt: bool,
    /// When FEAT_EVT is implemented, Trap TLB maintenance instructions that operate on the Inner Shareable domain.
    /// Otherwise, reserved.
    ttlbis: bool,
    /// When FEAT_EVT is implemented, Trap TLB maintenance instructions that operate on the Outer Shareable domain.
    /// Otherwise, reserved.
    ttlbos: bool,

    /// When FEAT_MTE2 is implemented, Allocation Tag Access.
    /// Otherwise, reserved.
    ata: bool,
    /// When FEAT_MTE2 is implemented, Default Cacheability Tagging.
    /// Otherwise, reserved.
    dct: bool,
    /// When FEAT_MTE2 is implemented, Trap ID group 5.
    /// Otherwise, reserved.
    tid5: bool,
    /// When FEAT_TWED is implemented, TWE Delay Enable.
    /// Otherwise, reserved.
    tweden: bool,
    /// When FEAT_TWED is implemented TWE Delay.
    /// Otherwise, reserved.
    twedel: u4,
};

/// DAIF.
///
/// Interrupt Mask Bits.
pub const Daif = packed struct(u64) {
    /// Reserved.
    _reserved0: u6 = 0,
    /// FIQ mask bit.
    f: bool,
    /// IRQ mask bit.
    i: bool,
    /// SError exception mask bit.
    a: bool,
    /// Watchpoint, Breakpoint, and Software Step exceptions mask bit.
    d: bool,
    /// Reserved.
    _reserved1: u54 = 0,
};

/// SPSR_ELx.
///
/// Saved Program Status Register.
pub const Spsr = packed struct(u64) {
    /// Aarch64 Exception level and selected Stack Pointer.
    ///
    /// - 0b0000: EL0
    /// - 0b0100: EL1 using SP_EL0 (ELt)
    /// - 0b0101: EL1 using SP_EL1 (EL1h)
    /// - 0b1000: EL2 using SP_EL0 (EL2t)
    /// - 0b1001: EL2 using SP_EL1 (EL2h)
    m_elsp: enum(u4) {
        el0 = 0b0000,
        el1t = 0b0100,
        el1h = 0b0101,
        el2t = 0b1000,
        el2h = 0b1001,
    },
    /// Execution state.
    m_es: u1,
    /// Reserved.
    _reserved0: u1 = 0,
    /// FIQ interrupt mask.
    f: bool,
    /// IRQ interrupt mask.
    i: bool,
    /// SError exception mask.
    a: bool,
    /// Debug exception mask.
    d: bool,
    /// When FEAT_BTI is implemented, Branch Type Indicator.
    btype: u2,
    /// When FEAT_SSBS is implemented, Speculative Store Bypass.
    ssbs: bool,
    /// When FEAT_NMI is implemented, All IRQ or FIQ interrupts mask.
    allint: bool,
    /// Reserved.
    _reserved1: u6 = 0,
    /// Illegal Execution state.
    il: bool,
    /// Software Step.
    ss: bool,
    /// When FEAT_PAN is implemented, Privileged Access Never.
    pan: bool,
    /// When FEAT_UAO is implemented, User Access Override.
    uao: bool,
    /// When FEAT_DIT is implemented, Data Independent Timing.
    dit: bool,
    /// When FEAT_MTE is implemented, Tag Check Override.
    tco: bool,
    /// Reserved.
    _reserved2: u2 = 0,
    /// Overflow Condition flag.
    v: bool,
    /// Carry Condition flag.
    c: bool,
    /// Zero Condition flag.
    z: bool,
    /// Negative Condition flag.
    n: bool,
    /// When FEAT_EBEP is implemented PMU exception mask bit.
    pm: bool,
    /// When FEAT_SEBEP is implemented, PMU exception pending bit.
    ppend: bool,
    /// When FEAT_GCS is implemented, Exception return state lock.
    exlock: bool,
    /// Reserved.
    _reserved3: u29 = 0,
};

/// VBAR_ELx.
///
/// Vector Base Address Register.
/// Holds the vector base address for any exception that is taken to ELx.
pub const Vbar = packed struct(u64) {
    /// Vector base address.
    addr: u64,
};

/// ESR_ELx.
///
/// Exception Syndrome Register.
/// Holds syndrome information for an exception taken to ELx.
pub const Esr = packed struct(u64) {
    /// Instruction Specific Syndrome.
    iss: u25,
    /// Instruction Length for synchronous exceptions.
    il: Length,
    /// Exception class.
    ec: Class,
    /// Instruction Specific Syndrome.
    iss2: u24,
    /// Reserved.
    _reserved: u8 = 0,

    pub const Class = enum(u6) {
        unknown = 0b000000,
        bti = 0b001011,
        illegal_exec_state = 0b001110,
        svc_a32 = 0b010001,
        hvc_a32 = 0b010010,
        smc_a32 = 0b010011,
        svc_a64 = 0b010101,
        hvc_a64 = 0b010110,
        smc_a64 = 0b010111,
        iabort_lower = 0b100000,
        iabort_cur = 0b100001,
        pc_align = 0b100010,
        dabort_lower = 0b100100,
        dabort_cur = 0b100101,
        sp_align = 0b100110,

        _,
    };

    pub const Length = enum(u1) {
        len16 = 0,
        len32 = 1,
    };

    /// Instruction Fault Status Code.
    ///
    /// ISS[5:0] when EC is `.iabort_lower` or `iabort_cur`.
    pub const Ifsc = enum(u6) {
        addr_size_lvl0 = 0b000000,
        addr_size_lvl1 = 0b000001,
        addr_size_lvl2 = 0b000010,
        addr_size_lvl3 = 0b000011,

        trans_lv0 = 0b000100,
        trans_lv1 = 0b000101,
        trans_lv2 = 0b000110,
        trans_lv3 = 0b000111,

        af_lv1 = 0b001001,
        af_lv2 = 0b001010,
        af_lv3 = 0b001011,
        af_lv0 = 0b001000,

        perm_lv0 = 0b001100,
        perm_lv1 = 0b001101,
        perm_lv2 = 0b001110,
        perm_lv3 = 0b001111,

        _,
    };

    /// ISS encoding for Data Abort.
    pub const IssDabort = packed struct(u25) {
        /// Data Fault Status Code.
        dfsc: Dfsc,
        /// Write not Read,
        ///
        /// Indicates whether a synchronous abort was caused by an instruction writing to a memory location,
        /// or by an instruction reading from a memory location.
        wnr: enum(u1) {
            read = 0,
            write = 1,
        },
        /// Stage 1 Page Table Walk.
        ///
        /// For a stage 2 fault, indicates whether the fault was a stage 2 fault on an access made for a stage 1 translation table walk.
        /// Otherwise, reserved.
        s1ptw: u1,
        /// Cache maintenance.
        cm: u1,
        /// External abort type.
        /// Otherwise, fixed to 0.
        ea: u1,
        /// FAR not Valid when a synchronous Externnal abort.
        fnv: bool,
        ///
        lst_set: u2,
        ///
        vncr: u1,
        ///
        ar_pfv: u1,
        /// When ISV is set, Sixty Four bit general-purpose register transfer.
        /// Width of the register accessed by the instruction is 64-bit.
        sf_fnp: bool,
        /// If ISV is set, Syndrome Register Transfer.
        /// The register number of the Wt/Xt/Rt operand of the faulting instruction.
        srt_wu: u5,
        ///
        sse_toplevel: u1,
        /// When ISV is set, Syndrome Access Size.
        ///
        /// Indicates the size of the access attempted by the faulting operation.
        sas: enum(u2) {
            byte = 0b00,
            halfword = 0b01,
            word = 0b10,
            doubleword = 0b11,
        },
        /// Instruction Syndrome Valid.
        ///
        /// Indicates whether the syndrome information in ISS[23:14] is valid.
        isv: bool,
    };

    /// Data Abort Fault Status Code.
    pub const Dfsc = enum(u6) {
        addr_size_lvl0 = 0b000000,
        addr_size_lvl1 = 0b000001,
        addr_size_lvl2 = 0b000010,
        addr_size_lvl3 = 0b000011,

        trans_lvl0 = 0b000100,
        trans_lvl1 = 0b000101,
        trans_lvl2 = 0b000110,
        trans_lvl3 = 0b000111,

        af_lvl0 = 0b001000,
        af_lvl1 = 0b001001,
        af_lvl2 = 0b001010,
        af_lvl3 = 0b001011,

        perm_lvl0 = 0b001100,
        perm_lvl1 = 0b001101,
        perm_lvl2 = 0b001110,
        perm_lvl3 = 0b001111,

        _,
    };
};

/// TCR_ELx.
///
/// Translation Control Register.
pub const Tcr = packed struct(u64) {
    /// The size offset parameter of the memory region addressed by TTBR_EL1.
    t0sz: u6,
    /// Reserved.
    _rsvd0: u1 = 0,
    /// Translation table walk disable for translations using TTBR0_EL1.
    epd0: u1 = 0,
    /// Inner cacheability attribute for memory associated with translation table walks using TTBR0_EL1.
    irgn0: Cacheability,
    /// Outer cacheability attribute for memory associated with translation table walks using TTBR0_EL1.
    orgn0: Cacheability,
    /// Shareability attribute for memory associated with translation table walks using TTBR0_EL1.
    sh0: Shareability,
    /// Granule size for the TTBR0_EL1.
    tg0: Tg0,
    /// The size offset of the memory region addressed by TTBR1_EL1.
    t1sz: u6,
    /// Selects whether TTBR0_EL1 or TTBR1_EL1 defines the ASID.
    a1: u1,
    /// Translation table walk disable for translations using TTBR1_EL1.
    epd1: u1 = 0,
    /// Inner cacheability attribute for memory associated with translation table walks using TTBR1_EL1.
    irgn1: Cacheability,
    /// Outer cacheability attribute for memory associated with translation table walks using TTBR1_EL1.
    orgn1: Cacheability,
    /// Shareability attribute for memory associated with translation table walks using TTBR1_EL1.
    sh1: Shareability,
    /// Granule size for the TTBR1_EL1.
    tg1: Tg1,
    /// Intermediate Physical Address Size.
    ips: u3,
    /// Reserved.
    _rsvd1: u1 = 0,
    /// ASID size.
    as: u1 = 0,
    /// Reserved.
    _rsvd2: u27 = 0,

    const Tg0 = enum(u2) {
        /// 4KiB
        size_4kib = 0b00,
        /// 64KiB
        size_64kib = 0b01,
        /// 16KiB
        size_16kib = 0b10,
    };

    const Tg1 = enum(u2) {
        /// 4KiB
        size_4kib = 0b10,
        /// 64KiB
        size_64kib = 0b01,
        /// 16KiB
        size_16kib = 0b11,
    };

    const Cacheability = enum(u2) {
        /// Normal memory, Non-cacheable.
        nc = 0b00,
        /// Normal memory, Write-Back Read-Allocate Write-Allocate Cacheable.
        wbrawac = 0b01,
        /// Normal memory, Write-Through Read-Allocate Write-Allocate Cacheable.
        wtranwac = 0b10,
        /// Normal memory, Write-Back Read-Allocate Write-Allocate Non-Cacheable.
        wbranwac = 0b11,
    };

    const Shareability = enum(u2) {
        /// Non-shareable.
        non = 0b00,
        /// Reserved.
        _reserved = 0b01,
        /// Outer Sharable.
        outer = 0b10,
        /// Inner Sharable.
        inner = 0b11,
    };
};

/// ID_AA64MMFR0_ELn.
///
/// Aarch64 Memory Model Feature Register 0.
/// Provides information about the implemented memory model and memory management support.
pub const IdAa64Mmfr0 = packed struct(u64) {
    /// Physical Address range supported.
    parange: PaRange,
    /// Number of ASID bits.
    asidbits: u4,
    /// BigEnd.
    bigend: u4,
    /// SNSMem.
    snsmem: u4,
    /// BigEndEL0.
    bigendel0: u4,
    /// TGran16.
    tgran16: u4,
    /// TGran64.
    tgran64: u4,
    /// TGran4.
    tgran4: u4,
    /// TGran16_2
    tgran16_2: u4,
    /// TGran64_2
    tgran64_2: u4,
    /// TGran4_2
    tgran4_2: u4,
    /// ExS.
    exs: u4,
    /// Reserved.
    _reserved0: u8 = 0,
    /// FGT.
    fgt: u4,
    /// ECV.
    ecv: u4,

    /// Physical Address range.
    const PaRange = enum(u4) {
        /// 32 bits, 4GB
        bits_32 = 0b0000,
        /// 36 bits, 64GB
        bits_36 = 0b0001,
        /// 40 bits, 1TB
        bits_40 = 0b0010,
        /// 42 bits, 4TB
        bits_42 = 0b0011,
        /// 44 bits, 16TB
        bits_44 = 0b0100,
        /// 48 bits, 256TB
        bits_48 = 0b0101,
        /// 52 bits, 1PB
        bits_52 = 0b0110,
        /// 56 bits, 64PB
        bits_56 = 0b1111,
    };
};

/// FAR_ELx.
///
/// Fault Address Register.
pub const Far = packed struct(u64) {
    /// Fault address.
    addr: u64,
};

/// PFAR_ELx.
///
/// Physical Fault Address Register.
pub const Pfar = packed struct(u64) {
    /// Physical fault address.
    addr: u64,
};

/// MAIR_ELx.
///
/// Memory Attribute Indirection Register.
pub const Mair = packed struct(u64) {
    attr0: u8,
    attr1: u8,
    attr2: u8,
    attr3: u8,
    attr4: u8,
    attr5: u8,
    attr6: u8,
    attr7: u8,
};

/// TTBR0_EL1.
///
/// Translation Table Base Register 0 EL1.
pub const Ttbr0El1 = packed struct(u64) {
    /// Translation table base address.
    addr: u48,
    /// ASID.
    asid: u16,
};

/// TTBR1_EL1.
///
/// Translation Table Base Register 0 EL1.
pub const Ttbr1El1 = packed struct(u64) {
    /// Translation table base address.
    addr: u48,
    /// ASID.
    asid: u16,
};

/// SCTLR_EL1.
///
/// System Control Register EL1.
pub const SctlrEl1 = packed struct(u64) {
    m: bool,
    a: bool,
    c: bool,
    sa: bool,
    sa0: bool,
    cp15ben: bool,
    naa: bool,
    itd: bool,

    sed: bool,
    uma: bool,
    enrctx: bool,
    eos: bool,
    i: bool,
    endb: bool,
    dze: bool,
    uct: bool,

    ntwi: bool,
    _rsvd0: u1 = 0,
    ntwe: bool,
    wxn: bool,
    tscxt: bool,
    iesb: bool,
    eis: bool,
    span: bool,

    e0e: bool,
    ee: bool,
    uci: bool,
    enda: bool,
    ntlsmd: bool,
    lsmaoe: bool,
    enib: bool,
    enia: bool,

    cmow: bool,
    mscen: bool,
    _rsvd1: u1 = 0,
    bt0: bool,
    bt1: bool,
    itfsb: bool,
    tcf0: u2,

    tcf: u2,
    ata0: bool,
    ata: bool,
    dssbs: bool,
    tweden: bool,
    twedel: u4,

    tmt0: bool,
    tmt: bool,
    tme0: bool,
    tme: bool,
    enasr: bool,
    enas0: bool,

    enals: bool,
    epan: bool,
    tcso0: bool,
    tcso: bool,
    entp2: bool,
    nmi: bool,
    spintmask: bool,
    tidcp: bool,
};

/// CNTPCT_ELx.
///
/// Counter-timer Physical Count Register.
pub const Cntpct = packed struct(u64) {
    /// Physical count value.
    value: u64,
};

/// CNTFRQ_EL0.
///
/// Counter-timer Frequency Register.
pub const Cntfrq = packed struct(u64) {
    /// Timer frequency.
    freq: u32,
    /// Reserved.
    _rsvd: u32 = 0,
};
