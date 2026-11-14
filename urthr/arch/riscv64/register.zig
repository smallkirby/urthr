//! RISC-V system registers module.
//!
//! ref. The RISC-V Instruction Set Manual, Volume II

/// comptime-only register definitions.
///
/// Entries must be sorted in alphabetical order in each group.
const definitions = &[_]@Tuple(&.{ @EnumLiteral(), type }){
    .{ .satp, Satp },
    .{ .sie, Sie },
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

/// Time CSR.
///
/// Available only when Zicntr extension is implemented.
pub const Time = packed struct(u64) {
    value: u64,
};
