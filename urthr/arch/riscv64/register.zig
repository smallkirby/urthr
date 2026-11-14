//! RISC-V system registers module.
//!
//! ref. The RISC-V Instruction Set Manual, Volume II

/// comptime-only register definitions.
///
/// Entries must be sorted in alphabetical order in each group.
const definitions = &[_]@Tuple(&.{ @EnumLiteral(), type }){
    .{ .satp, Satp },
    .{ .scause, Scause },
    .{ .sie, Sie },
    .{ .sip, Sip },
    .{ .sscratch, Sscratch },
    .{ .sstatus, Sstatus },
    .{ .stvec, Stvec },
    .{ .time, Time },
};

/// CSR register enum.
pub const Csr = blk: {
    var names: [definitions.len][]const u8 = undefined;
    var values: [definitions.len]u64 = undefined;

    for (definitions, 0..) |entry, i| {
        names[i] = @tagName(entry.@"0");
        values[i] = i;
    }

    break :blk @Enum(
        u64,
        .exhaustive,
        &names,
        &values,
    );
};

/// Get the corresponding type of a CSR enum.
pub fn Type(comptime s: Csr) type {
    for (definitions) |d| {
        if (d.@"0" == s) {
            return d.@"1";
        }
    }

    unreachable;
}

// =============================================================
// CSRs
// =============================================================

/// Supervisor Address Translation and Protection Register.
pub const Satp = packed struct(u64) {
    /// Physical page number of the root page table.
    ppn: u44,
    /// Address space identifier.
    asid: u16,
    /// Selects the current address-translation scheme.
    mode: Mode,

    const Mode = enum(u4) {
        /// No translation or protection.
        bare = 0,
        /// Page-based 39-bit virtual addressing.
        sv39 = 8,
        /// Page-based 48-bit virtual addressing.
        sv48 = 9,
        /// Page-based 57-bit virtual addressing.
        sv57 = 10,
        /// Page-based 64-bit virtual addressing.
        sv64 = 11,
    };
};

/// Supervisor Cause Register.
pub const Scause = packed struct(u64) {
    /// Exception code.
    code: Code = .{ ._raw = 0 },
    /// Whether the trap was caused by an interrupt.
    interrupt: bool,

    pub const Code = packed union {
        /// Interrupt code.
        i: Icode,
        /// Exception code.
        e: Ecode,
        /// Raw value of the represented code.
        _raw: u63,

        /// Raw integer value of the code.
        pub fn raw(self: Code) u63 {
            return self._raw;
        }
    };

    /// Exception codes for interrupts.
    pub const Icode = enum(u63) {
        /// Supervisor software interrupt.
        ssi = 1,
        /// Supervisor timer interrupt.
        sti = 5,
        /// Supervisor external interrupt.
        sei = 9,
        /// Counter-overflow interrupt.
        coi = 13,

        _,
    };

    /// Exception codes for non-interrupts.
    pub const Ecode = enum(u63) {
        /// Instruction address misaligned.
        ialign = 0,
        /// Instruction access fault.
        ifault = 1,
        /// Illegal instruction.
        illegal = 2,
        /// Breakpoint.
        breakpoint = 3,
        /// Load address misaligned.
        lalign = 4,
        /// Load access fault.
        lfault = 5,
        /// Store/AMO address misaligned.
        salign = 6,
        /// Store/AMO access fault.
        sfault = 7,
        /// Environment call from U-mode.
        ecall_u = 8,
        /// Environment call from S-mode.
        ecall_s = 9,
        /// Instruction page fault.
        ipf = 12,
        /// Load page fault.
        lpf = 13,
        /// Store/AMO page fault.
        spf = 15,
        /// Software check.
        scheck = 18,
        /// Hardware error.
        herr = 19,

        _,
    };
};

/// Supervisor Interrupt Enable Register. WARL.
pub const Sie = packed struct(u64) {
    /// Reserved.
    _0: u1 = 0,
    /// Supervisor-level software interrupts.
    ssie: bool,
    /// Reserved.
    _2: u3 = 0,
    /// Supervisor-level timer interrupts.
    stie: bool,
    /// Reserved.
    _6: u3 = 0,
    /// Supervisor-level external interrupts.
    seie: bool,
    /// Reserved.
    _10: u3 = 0,
    /// Local-counter-overflow interrupts.
    lcofie: bool,
    /// Reserved.
    _14: u50 = 0,
};

/// Supervisor Interrupt Pending Register.
pub const Sip = packed struct(u64) {
    /// Reserved.
    _0: u1 = 0,
    /// Supervisor-level software interrupt is pending.
    ssip: bool,
    /// Reserved.
    _2: u3 = 0,
    /// Supervisor-level timer interrupt is pending.
    stip: bool,
    /// Reserved.
    _6: u3 = 0,
    /// Supervisor-level external interrupt is pending.
    seip: bool,
    /// Reserved.
    _10: u3 = 0,
    /// Local-counter-overflow interrupt is pending.
    lcofip: bool,
    /// Reserved.
    _14: u50 = 0,
};

/// Supervisor Scratch Register.
pub const Sscratch = packed struct(u64) {
    value: u64,
};

/// Supervisor Status Register.
pub const Sstatus = packed struct(u64) {
    /// Reserved. WPRI.
    _0: u1 = 0,
    /// Disable or enable all interrupts in supervisor mode.
    sie: bool,
    /// Reserved. WPRI.
    _2: u3 = 0,
    /// Whether supervisor interrupts were enabled prior to trapping into supervisor mode.
    spie: bool,
    /// Endianness of explicit memory access mode from U-mode. WARL.
    ube: enum(u1) { little = 0, big = 1 },
    /// Reserved. WPRI.
    _6: u1 = 0,
    /// Privilege level at which a hart was executing before entering supervisor mode.
    spp: Spp,
    /// Vector extension status.
    vs: FsStatus,
    /// Reserved. WPRI.
    _11: u2 = 0,
    /// Floating-point extension status.
    fs: FsStatus,
    /// Extension status for custom extensions.
    xs: FsStatus,
    /// Reserved. WPRI.
    _17: u1 = 0,
    /// Allows Supervisor User Memory access.
    sum: bool,
    /// Make executable readable.
    mxr: bool,
    /// Reserved. WPRI.
    _20: u3 = 0,
    /// Supervisor previous expected landing pad.
    spelp: bool,
    /// S-mode disable trap.
    sdt: bool,
    /// Reserved. WPRI.
    _25: u7 = 0,
    /// Effective XLEN for U-mode.
    uxl: enum(u2) { @"32" = 0, @"64" = 1 },
    /// Reserved. WPRI.
    _34: u29 = 0,
    /// Some of FS, VS, or XS are dirty.
    sd: bool,

    pub const Spp = enum(u1) {
        /// User mode.
        user = 0,
        /// Supervisor mode.
        supervisor = 1,
    };

    pub const FsStatus = enum(u2) {
        /// Off.
        off = 0,
        /// Initial state.
        initial = 1,
        /// Clean state.
        clean = 2,
        /// Dirty state.
        dirty = 3,
    };
};

/// Supervisor Trap Vector Base Address Register. WARL.
pub const Stvec = packed struct(u64) {
    /// Vector mode.
    mode: Mode,
    /// Vector base address divided by 4.
    base: u62,

    pub const Mode = enum(u2) {
        /// All exceptions set PC to BASE.
        direct = 0,
        /// Asynchronous interrupts set PC to BASE + 4 * cause.
        vectored = 1,
    };
};

/// Time CSR.
///
/// Available only when Zicntr extension is implemented.
pub const Time = packed struct(u64) {
    value: u64,
};
