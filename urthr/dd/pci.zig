// =============================================================
// Module Definition
// =============================================================

/// PCI Header Type 1.
pub const HeaderType1 = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, HeaderVendorDevice },
    .{ 0x04, HeaderCommandStatus },
    .{ 0x08, HeaderRevClass },
    .{ 0x0C, HeaderBistLatCacheLine },

    .{ 0x10, HeaderBar0 },
    .{ 0x14, HeaderBar1 },
    .{ 0x18, HeaderBusNum },
    .{ 0x1C, HeaderIoBaseLimit },
    .{ 0x20, HeaderMemBaseLimit },
    .{ 0x24, HeaderPrefMemBaseLimit },
    .{ 0x28, HeaderPrefBaseUpper },
    .{ 0x2C, HeaderPrefLimitUpper },
    .{ 0x30, HeaderIoBaseUpper },
    .{ 0x34, HeaderCapPtr },
    .{ 0x38, HeaderExpansionRom },
    .{ 0x3C, HeaderInt },
    .{ 0x100, ExtCapHeader },
});

/// PCI Header Type 0.
pub const HeaderType0 = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, HeaderVendorDevice },
    .{ 0x04, HeaderCommandStatus },
    .{ 0x08, HeaderRevClass },
    .{ 0x0C, HeaderBistLatCacheLine },

    .{ 0x10, HeaderBar0 },
    .{ 0x14, HeaderBar1 },
    .{ 0x18, HeaderBar2 },
    .{ 0x1C, HeaderBar3 },
    .{ 0x20, HeaderBar4 },
    .{ 0x24, HeaderBar5 },
    .{ 0x28, HeaderCardbusCis },
    .{ 0x2C, HeaderSubsys },
    .{ 0x30, HeaderExpansionRom },
    .{ 0x34, HeaderCapPtr },
    .{ 0x3C, HeaderInt },
    .{ 0x100, ExtCapHeader },
});

/// PCIe Capability Structure.
pub const PcieCap = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, CapCap },
    .{ 0x0C, LinkCap1 },
    .{ 0x30, LinkControlStatus2 },
});

// =============================================================
// API
// =============================================================

/// Data type for function number.
const FunctionNum = u3;
/// Data type for device number.
const DeviceNum = u5;
/// Data type for bus number.
const BusNum = u8;

/// I/O interface for PCI Configuration Space.
pub fn ConfIo(Module: type) type {
    return struct {
        const Wrapper = @This();

        /// Access method for Configuration Space.
        method: Method,

        /// Target bus number.
        bus: BusNum = 0,
        /// Target device number.
        device: DeviceNum = 0,
        /// Target function number.
        function: FunctionNum = 0,

        pub const Method = union(enum) {
            /// Enhanced Configuration Access Mechanism (ECAM).
            ecam: EcamIo,
            /// Broadcom STB-specific access method.
            brcm: BrcmIo,
        };

        /// Set the target address.
        pub fn setAddress(self: *Wrapper, bus: BusNum, device: DeviceNum, function: FunctionNum) void {
            self.bus = bus;
            self.device = device;
            self.function = function;
        }

        /// Read from the specified register type.
        pub fn read(self: Wrapper, T: type) T {
            const roffset, _ = Module.getRegister(T);
            return self.readAt(roffset, T);
        }

        /// Read a field at the given offset as type T.
        pub fn readAt(self: Wrapper, offset: usize, T: type) T {
            _, const register = Module.getRegister(T);

            const target = switch (self.method) {
                inline else => |m| m.prepareIo(offset, self.bus, self.device, self.function),
            };

            return register.read(target);
        }

        /// Read raw integer at the given offset.
        pub fn readRawAt(self: Wrapper, offset: usize, T: type) T {
            const target = switch (self.method) {
                inline else => |m| m.prepareIo(offset, self.bus, self.device, self.function),
            };

            return @as(*const volatile T, @ptrFromInt(target)).*;
        }

        /// Write raw integer at the given offset.
        pub fn writeRawAt(self: Wrapper, offset: usize, value: u32) void {
            const target = switch (self.method) {
                inline else => |m| m.prepareIo(offset, self.bus, self.device, self.function),
            };

            @as(*volatile u32, @ptrFromInt(target)).* = value;
        }

        /// Read modify write the register at the given address.
        pub fn modify(self: Wrapper, T: type, value: anytype) void {
            const roffset, const register = Module.getRegister(T);

            const target = switch (self.method) {
                inline else => |m| m.prepareIo(roffset, self.bus, self.device, self.function),
            };

            register.modify(target, value);
        }

        /// ECAM access method.
        const EcamIo = struct {
            const Self = @This();

            /// Base address of PCI Configuration Space.
            base: usize,

            /// Prepare to read from or write to the address at the given offset and return the effective address.
            fn prepareIo(_: Self, roffset: usize, b: BusNum, d: DeviceNum, f: FunctionNum) usize {
                return bits.concatMany(u28, .{ b, d, f, @as(u12, @intCast(roffset)) });
            }
        };

        /// Broadcom STB -specific access method.
        const BrcmIo = struct {
            const Self = @This();

            /// Base address of configuration address.
            address_base: usize,
            /// Base address of configuration data.
            data_base: usize,

            const AddrReg = mmio.Register(u32, u32);

            /// Prepare to read from or write to the address at the given offset and return the effective address.
            fn prepareIo(self: Self, roffset: usize, b: BusNum, d: DeviceNum, f: FunctionNum) usize {
                // Set target configuration address.
                AddrReg.write(
                    self.address_base,
                    bits.concatMany(u32, .{ @as(u4, 0), b, d, f, @as(u12, 0) }),
                );

                return self.data_base + roffset;
            }
        };
    };
}

/// BAR information.
pub const BarInfo = struct {
    /// BAR index.
    index: usize,
    /// BAR type.
    type: BarType,
    /// Address.
    address: u64,
    /// Effective address mask.
    address_mask: u64,

    /// Get the size in bytes of the BAR.
    pub fn size(self: BarInfo) u64 {
        return ~self.address_mask + 1;
    }

    /// Set the address of the BAR.
    ///
    /// This function actually writes to the BAR register.
    pub fn setAddress(self: BarInfo, addr: u64, confio: anytype) void {
        rtt.expectEqual(0, addr & ~self.address_mask);

        const bar_base, _ = HeaderType0.getRegister(HeaderBar0);

        switch (self.type) {
            .io => {
                @panic("I/O BAR setting not implemented.");
            },
            .mem32 => {
                const bar_offset = bar_base + self.index * @sizeOf(HeaderBar0);
                const value = confio.readRawAt(bar_offset, u32);
                const new = @as(u32, @intCast(addr)) | (value & 0xF);
                confio.writeRawAt(bar_offset, new);
            },
            .mem64 => {
                @panic("64-bit BAR setting not implemented.");
            },
        }
    }
};

/// Type of BAR.
pub const BarType = enum {
    /// I/O space BAR.
    io,
    /// Memory space BAR (32-bit).
    mem32,
    /// Memory space BAR (64-bit).
    mem64,
};

/// Parse BARs.
///
/// `confio` must be configured to access the target device's configuration space beforehand.
pub fn parseBars(confio: anytype, out: []BarInfo) []const BarInfo {
    const bar_base, _ = HeaderType0.getRegister(HeaderBar0);

    var out_idx: usize = 0;
    var skip: bool = false;
    for (out, 0..) |*buf, i| {
        if (skip) {
            skip = false;
            continue;
        }

        const bar_offset = bar_base + i * @sizeOf(HeaderBar0);
        const value = confio.readRawAt(bar_offset, u32);

        // Test if BAR is implemented.
        confio.writeRawAt(bar_offset, 0xFFFF_FFFF);
        if (confio.readRawAt(bar_offset, u32) == 0) {
            // Unimplemented BAR.
            continue;
        }
        confio.writeRawAt(bar_offset, value);

        if (bits.isset(value, 0)) {
            // I/O space BAR.
            buf.* = .{
                .index = i,
                .type = .io,
                .address = value & 0xFFFF_FFFC,
                .address_mask = 0,
            };
            out_idx += 1;
        } else if (bits.extract(u2, value, 1) == 0x0) {
            // Memory space BAR (32-bit).
            confio.writeRawAt(bar_offset, 0xFFFF_FFFF);
            const mask = confio.readRawAt(bar_offset, u32);
            confio.writeRawAt(bar_offset, value);

            buf.* = .{
                .index = i,
                .type = .mem32,
                .address = value & mask,
                .address_mask = bits.concat(u64, @as(u32, 0xFFFF_FFFF), mask),
            };
            out_idx += 1;
        } else if (bits.extract(u2, value, 1) == 0x2) {
            // Memory space BAR (64-bit).
            const next_value = confio.readRawAt(bar_offset + 4, u32);
            confio.writeRawAt(bar_offset, 0xFFFF_FFFF);
            confio.writeRawAt(bar_offset + 4, 0xFFFF_FFFF);
            const mask = confio.readRawAt(bar_offset, u32);
            const next_mask = confio.readRawAt(bar_offset + 4, u32);
            confio.writeRawAt(bar_offset, value);
            confio.writeRawAt(bar_offset + 4, next_value);

            const mask64 = bits.concat(u64, next_mask, mask);
            const addr64 = bits.concat(u64, next_value, value) & mask64;

            buf.* = .{
                .index = i,
                .type = .mem64,
                .address = addr64,
                .address_mask = mask64,
            };

            out_idx += 1;
            skip = true;
        } else {
            // Unrecognized BAR type.
            break;
        }
    }

    return out[0..out_idx];
}

// =============================================================
// PCIe Configuration Header
// =============================================================

pub const HeaderVendorDevice = packed struct(u32) {
    /// Vendor ID.
    vendor_id: u16,
    /// Device ID.
    device_id: u16,
};

pub const HeaderCommandStatus = packed struct(u32) {
    // =========================================================
    // Command Register

    /// I/O Space Enable.
    io_space_enable: bool,
    /// Memory Space Enable.
    memory_space_enable: bool,
    /// Bus Master Enable.
    bus_master_enable: bool,
    /// Special Cycles Enable.
    special_cycles_enable: bool,
    /// Memory Write and Invalidate Enable.
    memory_write_invalidate_enable: bool,
    /// VGA Palette Snoop Enable.
    vga_palette_snoop_enable: bool,
    /// Parity Error Response Enable.
    parity_error_response_enable: bool,
    /// Reserved.
    _rsvd0: u1 = 0,
    /// SERR# Enable.
    serr_enable: bool,
    /// Fast Back-to-Back Enable.
    fast_back2back_enable: bool,
    /// Interrupt Disable.
    interrupt_disable: bool,
    /// Reserved.
    _rsvd1: u5 = 0,

    // =========================================================
    // Status Register

    /// Reserved.
    _rsvd2: u3 = 0,
    /// Interrupt Status.
    interrupt_status: bool,
    /// Capabilities List.
    capabilities_list: bool,
    /// 66 MHz Capable.
    _66mhz_capable: bool,
    /// Reserved.
    _rsvd3: u1 = 0,
    /// Fast Back-to-Back Capable.
    fast_back2back_capable: bool,
    /// Master Data Parity Error.
    master_data_parity_error: bool,
    /// DEVSEL# Timing.
    devsel_timing: u2,
    /// Signaled Target Abort.
    signaled_target_abort: bool,
    /// Received Target Abort.
    received_target_abort: bool,
    /// Received Master Abort.
    received_master_abort: bool,
    /// Signaled System Error.
    signaled_system_error: bool,
    /// Detected Parity Error.
    detected_parity_error: bool,
};

pub const HeaderRevClass = packed struct(u32) {
    /// Revision ID.
    revision_id: u8,
    /// Programming Interface.
    prog_if: u8,
    /// Sub Class Code.
    sub_class: u8,
    /// Base Class Code.
    base_class: u8,
};

pub const HeaderBistLatCacheLine = packed struct(u32) {
    /// Cache Line Size.
    cache_line_size: u8,
    /// Latency Timer.
    latency_timer: u8,
    /// Header Type.
    header_type: u8,
    /// BIST.
    bist: u8,
};

pub const HeaderBar0 = packed struct(u32) {
    /// Base Address Register 0.
    bar0: u32,
};

pub const HeaderBar1 = packed struct(u32) {
    /// Base Address Register 1.
    bar1: u32,
};

pub const HeaderBar2 = packed struct(u32) {
    /// Base Address Register 2.
    bar2: u32,
};

pub const HeaderBar3 = packed struct(u32) {
    /// Base Address Register 3.
    bar3: u32,
};

pub const HeaderBar4 = packed struct(u32) {
    /// Base Address Register 4.
    bar4: u32,
};

pub const HeaderBar5 = packed struct(u32) {
    /// Base Address Register 5.
    bar5: u32,
};

pub const HeaderBusNum = packed struct(u32) {
    /// Primary Bus Number.
    primary_bus_number: u8,
    /// Secondary Bus Number.
    secondary_bus_number: u8,
    /// Subordinate Bus Number.
    subordinate_bus_number: u8,
    /// Secondary Latency Timer.
    secondary_latency_timer: u8,
};

pub const HeaderIoBaseLimit = packed struct(u32) {
    /// I/O Base.
    io_base: u8,
    /// I/O Limit.
    io_limit: u8,
    /// Secondary Status.
    secondary_status: u16,
};

pub const HeaderMemBaseLimit = packed struct(u32) {
    /// Memory Base.
    mem_base: u16,
    /// Memory Limit.
    mem_limit: u16,
};

pub const HeaderPrefMemBaseLimit = packed struct(u32) {
    /// Prefetchable Memory Base.
    pref_mem_base: u16,
    /// Prefetchable Memory Limit.
    pref_mem_limit: u16,
};

pub const HeaderPrefBaseUpper = packed struct(u32) {
    /// Prefetchable Base Upper 32 bits.
    pref_base_upper: u32,
};

pub const HeaderPrefLimitUpper = packed struct(u32) {
    /// Prefetchable Limit Upper 32 bits.
    pref_limit_upper: u32,
};

pub const HeaderIoBaseUpper = packed struct(u32) {
    /// I/O Base Upper 16 bits.
    io_base_upper: u16,
    /// I/O Limit Upper 16 bits.
    io_limit_upper: u16,
};

pub const HeaderCapPtr = packed struct(u32) {
    /// Capabilities Pointer.
    cap_ptr: u8,
    /// Reserved.
    _rsvd: u24,
};

pub const HeaderExpansionRom = packed struct(u32) {
    /// Expansion ROM Base Address.
    expansion_rom_base: u32,
};

pub const HeaderInt = packed struct(u32) {
    /// Interrupt Line.
    interrupt_line: u8,
    /// Interrupt Pin.
    interrupt_pin: u8,
    /// Bridge Control.
    bridge_control: u16,
};

pub const HeaderCardbusCis = packed struct(u32) {
    /// Cardbus CIS Pointer.
    cardbus_cis_pointer: u32,
};

pub const HeaderSubsys = packed struct(u32) {
    /// Subsystem Vendor ID.
    subsys_vendor_id: u16,
    /// Subsystem ID.
    subsys_id: u16,
};

pub const ExtCapHeader = packed struct(u32) {
    /// Capability ID.
    id: u16,
    /// Version.
    version: u4,
    /// Next Capability Pointer.
    next: u12,
};

// =============================================================
// I/O Registers
// =============================================================

// =============================================================
// PCIe Capability Structure

pub const CapCap = packed struct(u32) {
    // =========================================================
    // PCIe Capability List Register

    /// Capability ID.
    id: u8,
    /// Next Capability Pointer.
    next: u8,

    // =========================================================
    // PCIe Capabilities Register

    /// Version.
    version: u4,
    /// Device/Port Type.
    device_port_type: u4,
    /// Slot Implemented.
    slot_implemented: bool,
    /// Interrupt Message Number Supported.
    interrupt_message_number: u5,
    /// Reserved.
    _rsvd: u2,
};

pub const LinkCap1 = packed struct(u32) {
    /// Max Link Speed.
    max_link_speed: LinkSpeed,
    /// Max Link Width.
    max_link_width: u6,
    /// ASPM Support / Active State Power Management Support.
    aspm_support: u2,
    /// L0s Exit Latency.
    l0s_exit_latency: u3,
    /// L1 Exit Latency.
    l1_exit_latency: u3,
    /// Clock Power Management Support.
    clock_pm: bool,
    /// Surprise Down Error Reporting Support.
    surprise_down_error_reporting: bool,
    /// Data Link Layer Link Active Reporting Support.
    dll_link_active_reporting: bool,
    /// Link Bandwidth Notification Support.
    link_bandwidth_notification: bool,
    /// ASPM Optionality Compliance.
    aspm_optionality_compliance: bool,
    /// Reserved.
    _rsvd: u1,
    /// Port Number.
    port: u8,

    pub const LinkSpeed = enum(u4) {
        /// 2.5 GT/s
        speed_2_5_gt = 1,
        /// 5.0 GT/s
        speed_5_0_gt = 2,
        /// 8.0 GT/s
        speed_8_0_gt = 3,
        /// 16.0 GT/s
        speed_16_0_gt = 4,
        /// 32.0 GT/s
        speed_32_0_gt = 5,
    };
};

pub const LinkControlStatus2 = packed struct(u32) {
    // =========================================================
    // Link Control 2 Register

    /// Target Link Speed.
    target_link_speed: LinkSpeed,
    /// Enter Compliance.
    enter_compliance: bool,
    /// Hardware Autonomous Speed Disable.
    hw_autonomous_speed_disable: bool,
    /// Selectable De-emphasis.
    selectable_deemphasis: bool,
    /// Transmit Margin.
    transmit_margin: u3,
    /// Enter Modified Compliance.
    enter_modified_compliance: bool,
    /// Compliance SOS.
    compliance_sos: bool,
    /// Compliance Preset/De-emphasis-
    compliance_preset: u4,

    // =========================================================
    // Link Status 2 Register

    /// Current De-emphasis Level.
    current_deemphasis: u1,
    /// Equalization 8.0 GT/s Complete.
    equalization_8_0_complete: bool,
    /// Equalization 8.0 GT/s Phase 1 Success.
    equalization_8_0_p1success: bool,
    /// Equalization 8.0 GT/s Phase 2 Success.
    equalization_8_0_p2success: bool,
    /// Equalization 8.0 GT/s Phase 3 Success.
    equalization_8_0_p3success: bool,
    /// Link Equalization Request 8.0 GT/s.
    link_equalization_request: bool,
    /// Retimer Presence Detected.
    retimer_presence_detected: bool,
    /// Two Retimer Presence Detected.
    two_retimers_presence_detected: bool,
    /// Crosslink Component Presence.
    crosslink_resolution: u2,
    /// Reserved.
    _rsvd: u2,
    /// Downstream Component Presence.
    downstream_component_presence: u3,
    /// DRS Message Received.
    drs_message_received: bool,

    pub const LinkSpeed = enum(u4) {
        /// 2.5 GT/s
        speed_2_5_gt = 1,
        /// 5.0 GT/s
        speed_5_0_gt = 2,
        /// 8.0 GT/s
        speed_8_0_gt = 3,
        /// 16.0 GT/s
        speed_16_0_gt = 4,
        /// 32.0 GT/s
        speed_32_0_gt = 5,
    };
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.pci);
const common = @import("common");
const bits = common.bits;
const mmio = common.mmio;
const rtt = common.rtt;
