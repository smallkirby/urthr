//! Intel 64 system registers module.
//!
//! ref. Intel® 64 and IA-32 Architectures Software Developer’s Manual Volume 4: Model-Specific Registers

/// comptime-only register definitions.
///
/// Entries must be sorted in alphabetical order in each group.
const definitions = &[_]@Tuple(&.{ @EnumLiteral(), type, u64 }){
    .{ .efer, Efer, 0xC000_0080 },
};

// =============================================================
// API
// =============================================================

/// System register enum.
pub const SystemReg = blk: {
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

/// Get the corresponding type of a system register enum.
pub fn Type(comptime s: SystemReg) type {
    for (definitions) |d| {
        if (d.@"0" == s) {
            return d.@"1";
        }
    }

    unreachable;
}

/// Get the corresponding address of a system register enum.
pub fn address(comptime s: SystemReg) u64 {
    inline for (definitions) |d| {
        if (d.@"0" == s) {
            return d.@"2";
        }
    }

    unreachable;
}

// =============================================================
// Control registers
// =============================================================

/// CR4 register.
pub const Cr4 = packed struct(u64) {
    /// Virtual-8086 mode extensions.
    vme: bool,
    /// Protected mode virtual interrupts.
    pvi: bool,
    /// Time stamp disable.
    tsd: bool,
    /// Debugging extensions.
    de: bool,
    /// Page size extension.
    pse: bool,
    /// Physical address extension. If unset, 32-bit paging.
    pae: bool,
    /// Machine check exception.
    mce: bool,
    /// Page global enable.
    pge: bool,
    /// Performance monitoring counter enable.
    pce: bool,
    /// Operating system support for FXSAVE and FXRSTOR instructions.
    osfxsr: bool,
    /// Operating system support for unmasked SIMD floating-point exceptions.
    osxmmexcpt: bool,
    /// Virtual machine extensions.
    umip: bool,
    /// 57-bit linear addresses. If set, CPU uses 5-level paging.
    la57: bool = false,
    /// Virtual machine extensions enable.
    vmxe: bool,
    /// Safer mode extensions enable.
    smxe: bool,
    /// Reserved.
    _14: u1 = 0,
    /// Enables the instructions RDFSBASE, RDGSBASE, WRFSBASE, and WRGSBASE.
    fsgsbase: bool,
    /// PCID enable.
    pcide: bool,
    /// XSAVE and processor extended states enable.
    osxsave: bool,
    /// Reserved.
    _18: u1 = 0,
    /// Supervisor mode execution protection enable.
    smep: bool,
    /// Supervisor mode access protection enable.
    smap: bool,
    /// Protection key enable.
    pke: bool,
    /// Control-flow Enforcement Technology enable.
    cet: bool,
    /// Protection keys for supervisor-mode pages enable.
    pks: bool,
    /// Reserved.
    _24: u39 = 0,
};

// =============================================================
// Register definitions
// =============================================================

/// IA32_EFER.
pub const Efer = packed struct(u64) {
    /// SYSCALL enable.
    sce: bool,
    /// Reserved.
    _1: u7 = 0,
    /// IA-32e mode enable.
    lme: bool,
    /// Reserved.
    _9: u1 = 0,
    /// IA-32e mode active.
    lma: bool,
    /// Execute disable bit enable.
    nxe: bool,
    /// Reserved.
    _12: u52 = 0,
};
