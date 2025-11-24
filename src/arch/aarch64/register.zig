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
