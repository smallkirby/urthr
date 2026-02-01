//! Generic Interrupt Controller v3 (GICv3).
//!
//! Supports only Group 1 Non-Secure interrupts.
//! Supports only a single CPU cluster.

/// Set the address of GICD and GICR.
pub fn setBase(gicd_base: usize, gicr_base: usize) void {
    gicd.mod.setBase(gicd_base);
    gicr.base = gicr_base;
}

/// Initialize Distributor.
pub fn initGlobal() void {
    const implementer_arm = 0x43B;
    rtt.expectEqual(implementer_arm, gicd.mod.read(gicd.Iidr).implementer);

    // Disable distributor first.
    gicd.mod.modify(gicd.Ctlr, .{
        .enable_grp0 = false,
        .enable_grp1 = false,
    });
    gicd.waitRwp();

    // Find the number of Redistributor frames.
    var max_redist_ix: usize = 0;
    while (!gicr.getRdMod(max_redist_ix).read(gicr.Typer1).last) : (max_redist_ix += 1) {}
    gicr.num_redists = max_redist_ix + 1;

    // Enable affinity routing.
    gicd.mod.modify(gicd.Ctlr, .{
        .are = true,
    });
    gicd.waitRwp();

    // Disable all SPIs.
    gicd.num_interrupts = (@as(usize, gicd.mod.read(gicd.Typer).it_lines_number) + 1) * 32;
    for (spi_start..gicd.num_interrupts) |id| {
        gicd.setEnable(id, false);
    }

    // Set all SPIs to level-triggered, route to CPU#0 and  G1NS.
    const cpu0aff = am.mrsi(.mpidr_el1);
    for (spi_start..gicd.num_interrupts) |id| {
        gicd.setTriggerType(id, .level);
        gicd.setGroup(id, .g1ns);
        gicd.setRoute(id, cpu0aff);
    }

    // Enable distributor.
    gicd.mod.modify(gicd.Ctlr, .{
        .enable_grp1 = true,
    });
    gicd.waitRwp();
}

/// Initialize Redistributor for the current AP.
pub fn initLocal() void {
    const cpu = getCpuId();
    const rd = gicr.getRdMod(cpu);
    const sgi = gicr.getSgiMod(cpu);

    // Wake up the redistributor.
    rd.modify(gicr.Waker, .{ .processor_sleep = false });
    while (rd.read(gicr.Waker).children_asleep) {
        std.atomic.spinLoopHint();
    }

    // Disable all SGIs and PPIs.
    for (0..spi_start) |id| {
        gicr.setEnable(sgi, id, false);
    }

    // Configure all SGIs and PPIs as Non-Secure Group 1.
    for (0..spi_start) |id| {
        gicr.setGroup(sgi, id, .g1ns);
    }

    // Configure CPU interface.
    am.msr(.icc_pmr_el1, reg.IccPmr{
        .priority = 0xFF,
    });
    am.msr(.icc_bpr0_el1, reg.IccBpr{
        .bpr = 0,
    });
    am.msr(.icc_bpr1_el1, reg.IccBpr{
        .bpr = 0,
    });

    // Enable CPU interface.
    var igrpen1 = am.mrs(.icc_igrpen1_el1);
    igrpen1.enable = true;
    am.msr(.icc_igrpen1_el1, igrpen1);
}

/// Get the interrupt ID of the signaled interrupt.
pub fn readIar() u32 {
    return am.mrs(.icc_iar1_el1).intid;
}

/// Signal end of interrupt.
pub fn eoi(iar: u32) void {
    am.msr(.icc_eoir1_el1, reg.IccEoir1El1{
        .intid = @intCast(iar),
    });
}

/// Send a SGI to the specified interfaces.
///
/// Supports only affnity level 0.
pub fn sendSgi(id: u4, target: []const u8) void {
    var target_list: u16 = 0;
    for (target) |cpu_id| {
        target_list = bits.set(target_list, cpu_id);
    }

    am.msr(.icc_sgi1r_el1, reg.IccSgi1r{
        .aff1 = 0,
        .aff2 = 0,
        .aff3 = 0,
        .target_list = target_list,
        .intid = id,
        .irm = .specified,
    });
}

/// Interrupt group.
const Group = enum {
    /// Group 1 Non-Secure.
    g1ns,
};

/// Interrupt trigger type.
const Trigger = enum {
    /// Level-sensitive.
    level,
    /// Edge-triggered.
    edge,
};

// =============================================================
// Distributor
// =============================================================

/// First SGI interrupt ID.
const sgi_start = 0;
/// First PPI interrupt ID.
const ppi_start = 16;
/// First SPI interrupt ID.
const spi_start = 32;

const gicd = struct {
    var mod = mmio.Module(.{ .size = u32 }, &.{
        .{ 0x0000, Ctlr },
        .{ 0x0004, Typer },
        .{ 0x0008, Iidr },
        .{ 0x0080, mmio.Marker(.igroupr) },
        .{ 0x0100, mmio.Marker(.isenabler) },
        .{ 0x0180, mmio.Marker(.icenabler) },
        .{ 0x0C00, mmio.Marker(.icfgr) },
        .{ 0x0D00, mmio.Marker(.igrpmodr) },
        .{ 0x6100, mmio.Marker(.irouter) },
    }){};

    /// Number of interrupts supported.
    var num_interrupts: usize = 0;

    /// Enable or disable an SPI interrupt.
    pub fn setEnable(id: usize, enable: bool) void {
        rtt.expect(id < num_interrupts);
        rtt.expect(id >= spi_start);

        const reg_index = id / 32;
        const bit_index = id % 32;

        const ptr: [*]volatile u32 = @ptrFromInt(if (enable)
            mod.getMarkerAddress(.isenabler)
        else
            mod.getMarkerAddress(.icenabler));

        ptr[reg_index] = bits.set(@as(u32, 0), bit_index);
    }

    /// Set the trigger type of an interrupt.
    pub fn setTriggerType(id: usize, trigger: Trigger) void {
        rtt.expect(id < num_interrupts);

        const reg_index = id / 16;
        const bit_index = (id % 16) * 2 + 1;

        const ptr: [*]volatile u32 = @ptrFromInt(mod.getMarkerAddress(.icfgr));
        const cur = ptr[reg_index];

        ptr[reg_index] = switch (trigger) {
            .level => bits.unset(cur, bit_index),
            .edge => bits.set(cur, bit_index),
        };
    }

    /// Set the affinity routing for an SPI.
    pub fn setRoute(id: usize, aff: u64) void {
        rtt.expect(id < num_interrupts);
        rtt.expect(id >= spi_start);

        const ptr: [*]volatile u64 = @ptrFromInt(mod.getMarkerAddress(.irouter));
        ptr[id] = aff;
    }

    /// Set the interrupt group of an SPI.
    pub fn setGroup(id: usize, group: Group) void {
        rtt.expect(id < num_interrupts);
        rtt.expect(id >= spi_start);

        const reg_index = id / 32;
        const bit_index = id % 32;

        // IGROUPR
        {
            const ptr: [*]volatile u32 = @ptrFromInt(mod.getMarkerAddress(.igroupr));
            const cur = ptr[reg_index];
            ptr[reg_index] = switch (group) {
                .g1ns => bits.set(cur, bit_index),
            };
        }

        // IGRPMODR
        {
            const ptr: [*]volatile u32 = @ptrFromInt(mod.getMarkerAddress(.igrpmodr));
            const cur = ptr[reg_index];
            ptr[reg_index] = switch (group) {
                .g1ns => bits.unset(cur, bit_index),
            };
        }
    }

    /// Block until the RWP bit is cleared.
    fn waitRwp() void {
        while (mod.read(Ctlr).rwp) {
            std.atomic.spinLoopHint();
        }
    }

    /// Distributor Control Register.
    ///
    /// Enables interrupts and affinity routing.
    const Ctlr = packed struct(u32) {
        /// When `.are` is set, Enable Group 0 interrupts. Otherwise, reserved.
        enable_grp0: bool,
        /// When `.are` is set, Enable Group 1 interrupts. Otherwise, reserved.
        enable_grp1: bool,
        /// Reserved.
        _rsvd0: u2 = 0,
        /// Affinity routing enable.
        are: bool,
        /// Reserved.
        _rsvd1: u26 = 0,
        /// Register Write Pending (RO).
        ///
        /// Indicates that a write operation to the GICD_CTLR is in progress.
        rwp: bool,
    };

    /// Interrupt Controller Type Register.
    const Typer = packed struct(u32) {
        /// Number of interrupt lines.
        it_lines_number: u5,
        /// Reserved or not implemented.
        _rsvd: u27,
    };

    /// Distributor Implementer Identification Register.
    const Iidr = packed struct(u32) {
        /// Implementer.
        implementer: u12,
        /// Revision.
        revision: u4,
        /// Variant.
        variant: u4,
        /// Reserved.
        _rsvd: u4 = 0,
        /// Product identifier.
        product: u8,
    };
};

// =============================================================
// Redistributor
// =============================================================

const gicr = struct {
    /// RD_base frame module.
    const Redist = mmio.Module(.{ .size = u32 }, &.{
        .{ 0x000, Ctlr },
        .{ 0x008, Typer1 },
        .{ 0x00C, Typer2 },
        .{ 0x014, Waker },
    });

    /// SGI_base frame module.
    const Sgi = mmio.Module(.{ .size = u32 }, &.{
        .{ 0x080, mmio.Marker(.igroupr) },
        .{ 0x100, mmio.Marker(.isenabler) },
        .{ 0x180, mmio.Marker(.icenabler) },
        .{ 0xD00, mmio.Marker(.igrpmodr) },
    });

    /// Size in bytes of a single redistributor region.
    const frame_size = 0x2_0000;
    /// Offset of the SGI frame within a redistributor region.
    const sgi_offset = 0x1_0000;

    /// Base address of the redistributor frames.
    var base: usize = undefined;

    /// Number of redistributor frames.
    var num_redists: usize = std.math.maxInt(usize);

    /// Get the Redistributor frame for the given CPU.
    pub fn getRdMod(cpu: usize) Redist {
        rtt.expect(cpu < num_redists);

        var module = Redist{};
        module.setBase(base + cpu * frame_size);

        return module;
    }

    /// Get the SGI frame for the given CPU.
    pub fn getSgiMod(cpu: usize) Sgi {
        rtt.expect(cpu < num_redists);

        var module = Sgi{};
        module.setBase(base + cpu * frame_size + sgi_offset);

        return module;
    }

    /// Enale or disable an SGI or PPI interrupt.
    pub fn setEnable(sgi: Sgi, id: usize, enable: bool) void {
        rtt.expect(id < spi_start);

        const bit_index = id % 32;

        const ptr: [*]volatile u32 = @ptrFromInt(if (enable)
            sgi.getMarkerAddress(.isenabler)
        else
            sgi.getMarkerAddress(.icenabler));

        ptr[0] = bits.set(@as(u32, 0), bit_index);
    }

    /// Set the interrupt group of an SGI or PPI.
    pub fn setGroup(sgi: Sgi, id: usize, group: Group) void {
        rtt.expect(id < spi_start);

        const bit_index = id % 32;

        // IGROUPR0
        {
            const ptr: [*]volatile u32 = @ptrFromInt(sgi.getMarkerAddress(.igroupr));
            const cur = ptr[0];
            ptr[0] = switch (group) {
                .g1ns => bits.set(cur, bit_index),
            };
        }

        // IGRPMODR0
        {
            const ptr: [*]volatile u32 = @ptrFromInt(sgi.getMarkerAddress(.igrpmodr));
            const cur = ptr[0];
            ptr[0] = switch (group) {
                .g1ns => bits.unset(cur, bit_index),
            };
        }
    }

    /// Block until the RWP bit is cleared.
    fn waitRwp(rd: Redist) void {
        while (rd.read(Ctlr).rwp) {
            std.atomic.spinLoopHint();
        }
    }

    /// Redistributor Control Register.
    const Ctlr = packed struct(u32) {
        /// LPI support is enabled.
        enable_lpis: bool,
        /// Clear Enable Supported.
        ces: bool,
        /// LPI invalidate registers supported.
        ir: bool,
        /// Register Write Pending (RO).
        rwp: bool,
        /// Reserved.
        _rsvd0: u20 = 0,
        /// Disable Processor selection for Group 0 interrupts.
        dpg0: bool,
        /// Disable Processor selection for Group 1 Non-Secure interrupts.
        dpg1ns: bool,
        /// Disable Processor selection for Group 1 Secure interrupts.
        dpg1s: bool,
        /// Reserved.
        _rsvd1: u4 = 0,
        /// Upstream Write Pending (RO).
        ///
        /// Indicates whether all upstream writes have been communicated to the Distributor.
        uwp: bool,
    };

    /// Redistributor Type Register 1.
    const Typer1 = packed struct(u32) {
        /// Whether the GIC supports physical LPIs.
        plpis: bool,
        /// Whether the GIC supports virtual LPIs.
        vlpis: bool,
        /// Controls the functionality of GICR_VPENDBASER.Dirty.
        dirty: bool,
        /// Whether this Redistributor supports direct injection of LPIs.
        direct_lpi: bool,
        /// Whether this Redistributor is the highest-numbered Redistributor in a series of contiguous Redistributors.
        last: bool,
        /// Sets support for GICR_CTLR.DPG* bits.
        dpgs: bool,
        /// Reserved.
        mpam: bool,
        /// Reserved.
        rvpeid: bool,
        /// Unique ID for the PE.
        proc_num: u16,
        /// The scope of the CommonLPIAff group.
        common_lpi_aff: u2,
        /// Reserved.
        vsgi: bool,
        /// Reserved.
        ppi_num: u5,
    };

    /// Redistributor Type Register 2.
    const Typer2 = packed struct(u32) {
        /// The identity of the PE associated with this Redistributor.
        affinity_value: u32,
    };

    /// Redistributor Wake Register.
    const Waker = packed struct(u32) {
        /// Reserved.
        _rsvd0: u1 = 0,
        /// Processor Sleep.
        ///
        /// If false, this PE is not in, and is not entering, a low power state.
        processor_sleep: bool,
        /// Children Asleep (RO).
        ///
        /// If true, all interfaces to the connected PE are quiesced.
        children_asleep: bool,
        /// Reserved.
        _rsvd1: u29 = 0,
    };
};

// =============================================================
// Utility
// =============================================================

/// Get the Processor ID of the calling PE.
pub fn getCpuId() u8 {
    return am.mrs(.mpidr_el1).aff0;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const bits = common.bits;
const mmio = common.mmio;
const rtt = common.rtt;
const am = @import("asm.zig");
const reg = @import("register.zig");
