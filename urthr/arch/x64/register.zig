//! Intel 64 system registers module.
//!
//! ref. Intel® 64 and IA-32 Architectures Software Developer’s Manual Volume 4: Model-Specific Registers

/// comptime-only register definitions.
///
/// Entries must be sorted in address order in each group.
const definitions = &[_]@Tuple(&.{ @EnumLiteral(), type, u64 }){
    .{ .apic_base, ApicBase, 0x0000_001B },
    .{ .pat, Pat, 0x0000_0277 },
    .{ .tsc_deadline, TscDeadline, 0x0000_06E0 },
    .{ .efer, Efer, 0xC000_0080 },
    .{ .star, Star, 0xC000_0081 },
    .{ .lstar, Lstar, 0xC000_0082 },
    .{ .fmask, Fmask, 0xC000_0084 },
    .{ .fs_base, FsBase, 0xC000_0100 },
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

/// RFLAGS
pub const Rflags = packed struct(u64) {
    /// Carry flag.
    cf: bool,
    /// Reserved.
    _1: u1 = 1,
    /// Parity flag.
    pf: bool,
    /// Reserved.
    _3: u1 = 0,
    /// Auxiliary carry flag.
    af: bool,
    /// Reserved.
    _5: u1 = 0,
    /// Zero flag.
    zf: bool,
    /// Sign flag.
    sf: bool,
    /// Trap flag.
    tf: bool,
    /// Interrupt enable flag.
    ie: bool,
    /// Direction flag.
    df: bool,
    /// Overflow flag.
    of: bool,
    /// IOPL (I/O privilege level).
    iopl: u2,
    /// Nested task flag.
    nt: bool,
    /// Reserved. Must be 0.
    md: u1 = 0,
    /// Resume flag.
    rf: bool,
    /// Virtual 8086 mode flag.
    vm: bool,
    /// Alignment check.
    ac: bool,
    /// Virtual interrupt flag.
    vif: bool,
    /// Virtual interrupt pending.
    vip: bool,
    /// CPUID support.
    id: bool,
    /// Reserved.
    _22: u8 = 0,
    /// Reserved.
    aes: bool,
    /// Alternate instruction set enabled.
    ai: bool,
    /// Reserved.
    _32: u32 = 0,
};

/// IA32_FS_BASE.
pub const FsBase = packed struct(u64) {
    addr: u64,
};

// =============================================================
// MSRs
// =============================================================

/// IA32_APIC_BASE.
pub const ApicBase = packed struct(u64) {
    /// Reserved.
    _0: u8 = 0,
    /// Whether the running CPU is the bootstrap processor.
    bsp: bool,
    /// Reserved.
    _9: u2 = 0,
    /// APIC global enable.
    en: bool,
    /// Physical base address of the local APIC, shifted right by 12 bits.
    base: u20,
    /// Reserved.
    _32: u32 = 0,
};

/// IA32_TSC_DEADLINE.
pub const TscDeadline = packed struct(u64) {
    value: u64,
};

/// IA32_STAR.
pub const Star = packed struct(u64) {
    /// Reserved.
    _0: u32 = 0,
    /// CS/SS selectors loaded on SYSCALL.
    ///
    /// CS is set to this value, SS is set to this value + 8.
    syscall_sel: u16,
    /// CS/SS selectors loaded on SYSRET.
    ///
    /// SS is set to this value + 8, CS is set to this value + 16.
    sysret_sel: u16,
};

/// IA32_LSTAR.
pub const Lstar = packed struct(u64) {
    /// Target RIP for 64-bit mode calling program.
    addr: u64,
};

/// IA32_FMASK.
pub const Fmask = packed struct(u64) {
    /// RFLAGS bits cleared on SYSCALL entry.
    mask: u64,
};

/// Memory types that can be encoded with PAT.
pub const PatType = enum(u3) {
    /// Uncacheable.
    uc = 0,
    /// Write Combining.
    wc = 1,
    /// Write Through.
    wt = 4,
    /// Write Protected.
    wp = 5,
    /// Write Back.
    wb = 6,
    /// Uncached (UC-).
    uc_minus = 7,
};

/// IA32_PAT.
///
/// Default value is set to its reset value.
pub const Pat = packed struct(u64) {
    /// PA0
    pa0: PatType = .wb,
    /// Reserved.
    _3: u5 = 0,
    /// PA1
    pa1: PatType = .wt,
    /// Reserved.
    _11: u5 = 0,
    /// PA2
    pa2: PatType = .uc_minus,
    /// Reserved.
    _19: u5 = 0,
    /// PA3
    pa3: PatType = .uc,
    /// Reserved.
    _27: u5 = 0,
    /// PA4
    pa4: PatType = .wb,
    /// Reserved.
    _35: u5 = 0,
    /// PA5
    pa5: PatType = .wt,
    /// Reserved.
    _43: u5 = 0,
    /// PA6
    pa6: PatType = .uc_minus,
    /// Reserved.
    _51: u5 = 0,
    /// PA7
    pa7: PatType = .uc,
    /// Reserved.
    _59: u5 = 0,
};

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
