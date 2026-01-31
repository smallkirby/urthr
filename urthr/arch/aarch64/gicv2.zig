//! Generic Interrupt Controller v2 (GICv2).

/// Set the base address of GICD.
pub fn setBase(addr: usize) void {
    const gicd_offset = 0x1000;
    const gicc_offset = 0x2000;

    gicd.mod.setBase(addr + gicd_offset);
    gicc.mod.setBase(addr + gicc_offset);
}

/// Initialize Distributor.
pub fn initGlobal() void {
    const implementer_arm = 0x43B;
    rtt.expectEqual(implementer_arm, gicd.mod.read(gicd.Iidr).implementer);

    // Disable distributor first.
    gicd.mod.modify(gicd.Ctlr, .{ .enable = false });

    // Disable all interrupts.
    gicd.num_interrupts = @as(usize, gicd.mod.read(gicd.Typer).it_lines_number) * 32;
    for (spi_start..gicd.num_interrupts) |id| {
        gicd.setEnable(id, false);
    }

    // Set all SPIs to level-triggered and target CPU0.
    for (spi_start..gicd.num_interrupts) |id| {
        gicd.setTriggerType(id, .level);
        gicd.setTargetCpu(id, 0b1);
    }

    // Enable distributor.
    gicd.mod.modify(gicd.Ctlr, .{ .enable = true });
}

/// Initialize CPU interface for the current AP.
pub fn initLocal() void {
    // Set priority mask to allow all priorities.
    gicc.mod.modify(gicc.Pmr, .{ .priority = 0xFF });

    // Enable CPU interface.
    gicc.mod.modify(gicc.Ctlr, .{ .enable = true });

    asm volatile ("isb");
}

/// Send a SGI to the specified interfaces.
pub fn sendSgi(id: u4, target: []const u8) void {
    gicd.sendSgi(id, target);
}

/// Get the interrupt ID of the signaled interrupt.
///
/// This function must be followed by a call to `eoi()`.
/// When this function is called before calling `eoi()`,
/// you lose the way to notify the end of the previous interrupt.
pub fn readIar() gicc.Iar {
    return gicc.mod.read(gicc.Iar);
}

/// Signal end of interrupt.
///
/// The value returned by `readIar()` must be passed to this function without modification.
pub fn eoi(iar: gicc.Iar) void {
    gicc.mod.write(gicc.Eoir, gicc.Eoir{
        .interrupt_id = iar.interrupt_id,
        .cpuid = iar.cpuid,
    });
}

// =============================================================
// Distributor
// =============================================================

/// First SPI interrupt ID.
const spi_start: usize = 32;

const gicd = struct {
    /// GICD module.
    ///
    /// All registers are 32-bit wide except that the following registers support byte access:
    /// - GICD_IPRIORITYRn
    /// - GICD_ITARGETSRn
    /// - GICD_CPENDSGIRn
    /// - GICD_SPENDSGIRn
    var mod = mmio.Module(.{ .size = u32 }, &.{
        .{ 0x000, Ctlr },
        .{ 0x004, Typer },
        .{ 0x008, Iidr },
        .{ 0x100, mmio.Marker(.isenabler) },
        .{ 0x180, mmio.Marker(.icenabler) },
        .{ 0x200, mmio.Marker(.ispendr) },
        .{ 0x280, mmio.Marker(.icpendr) },
        .{ 0x800, mmio.Marker(.itargetsr) },
        .{ 0xC00, mmio.Marker(.icfgr) },
        .{ 0xF00, Sgir },
    }){};

    /// Number of interrupts supported.
    var num_interrupts: usize = 0;

    /// Enable or disable an interrupt.
    pub fn setEnable(id: usize, enable: bool) void {
        rtt.expect(id < gicd.num_interrupts);
        rtt.expect(id >= spi_start); // Writes to SGIs are ignored.

        const reg_index = id / 32;
        const bit_index = id % 32;

        const ptr: [*]volatile u32 = @ptrFromInt(if (enable)
            mod.getMarkerAddress(.isenabler)
        else
            mod.getMarkerAddress(.icenabler));

        ptr[reg_index] = bits.set(@as(u32, 0), bit_index);
    }

    const Trigger = enum {
        /// Level-sensitive.
        level,
        /// Edge-triggered.
        edge,
    };

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

    /// Set the target CPUs for an interrupt.
    pub fn setTargetCpu(id: usize, cpu_mask: u8) void {
        rtt.expect(id < num_interrupts);
        rtt.expect(id >= spi_start);

        const reg_index = id / 4;
        const byte_index = id % 4;

        const ptr: [*]volatile u32 = @ptrFromInt(mod.getMarkerAddress(.itargetsr));
        const cur = ptr[reg_index];

        const shift: u5 = @intCast(byte_index * 8);
        const mask: u32 = @as(u32, 0xFF) << shift;
        const value = (cur & ~mask) | (@as(u32, cpu_mask) << shift);

        ptr[reg_index] = value;
    }

    /// Send a Software Generated Interrupt to the specified interfaces.
    pub fn sendSgi(id: u4, target: []const u8) void {
        var target_list: u8 = 0;
        for (target) |cpu_id| {
            target_list = bits.set(target_list, cpu_id);
        }

        mod.write(Sgir, Sgir{
            .sgi_id = id,
            .target_list = target_list,
            .filter = .filter,
        });
    }

    /// Distributor Control Register.
    const Ctlr = packed struct(u32) {
        /// Global enable for forwarding pending interrupts from the Distributor to the CPU interfaces.
        enable: bool,
        /// Reserved.
        _rsvd: u31,
    };

    /// Interrupt Controller Type Register.
    const Typer = packed struct(u32) {
        /// Number of interrupt lines implemented.
        ///
        /// The number of interrupt lines is equal to 32 * (it_lines_number + 1).
        it_lines_number: u5,
        /// Number of implemented CPU interfaces - 1.
        cpu_number: u3,
        /// Reserved.
        _rsvd0: u2 = 0,
        /// Whether the GIC implements the Security Extensions.
        security_extn: bool,
        /// If the GIC implements the Security Extensions,
        /// the maximum number of implemented lockable SPIs.
        lspi: u5,
        /// Reserved.
        _rsvd1: u16 = 0,
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

    /// Software Generated Interrupt Register.
    const Sgir = packed struct(u32) {
        /// Software Generated Interrupt ID.
        sgi_id: u4,
        /// Reserved.
        _rsvd0: u11 = 0,
        /// Required security value of the SGI (implemented only if the Security Extensions are implemented).
        nsatt: u1 = 0,
        /// CPU Target List.
        target_list: u8,
        /// Filter mode.
        filter: Target = .filter,
        /// Reserved.
        _rsvd1: u6 = 0,

        const Target = enum(u2) {
            /// Forward to the CPU interfaces specified in the Target List.
            filter = 0b00,
            /// Forward to all CPU interfaces except the caller.
            all = 0b01,
            /// Forward to the calling CPU interface only.
            self = 0b10,
            /// Reserved.
            _rsvd = 0b11,
        };
    };
};

// =============================================================
// CPU Interface
// =============================================================

const gicc = struct {
    var mod = mmio.Module(.{ .size = u32 }, &.{
        .{ 0x000, Ctlr },
        .{ 0x004, Pmr },
        .{ 0x008, Bpr },
        .{ 0x00C, Iar },
        .{ 0x010, Eoir },
    }){};

    /// CPU Interface Control Register.
    const Ctlr = packed struct(u32) {
        /// Enable for the signaling of Group 1 interrupts by the CPU interface to the connected processor.
        enable: bool,
        /// Reserved.
        _rsvd: u31 = 0,
    };

    /// Interrupt Priority Mask Register.
    const Pmr = packed struct(u32) {
        /// Priority mask.
        ///
        /// If the priority of an interrupt is higher than the value indicated in this field,
        /// the interrupt is signaled to the connected processor.
        priority: u8,
        /// Reserved.
        _rsvd: u24 = 0,
    };

    /// Binary Point Register.
    const Bpr = packed struct(u32) {
        /// Binary point.
        binary_point: u3,
        /// Reserved.
        _rsvd: u29 = 0,
    };

    /// Interrupt Acknowledge Register.
    const Iar = packed struct(u32) {
        /// Interrupt ID.
        interrupt_id: u10,
        /// For SGI, the processor ID that requested the interrupt.
        cpuid: u3,
        /// Reserved.
        _rsvd: u19 = 0,
    };

    /// End of Interrupt Register.
    const Eoir = packed struct(u32) {
        /// Interrupt ID.
        interrupt_id: u10,
        /// For SGI, the processor ID that requested the interrupt.
        cpuid: u3,
        /// Reserved.
        _rsvd: u19 = 0,
    };
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const bits = common.bits;
const mmio = common.mmio;
const rtt = common.rtt;
