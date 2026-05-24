// =============================================================
// Module Definition
// =============================================================

/// PCI Header Type 1.
///
/// For bridges and switches.
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
///
/// For regular endpoint devices.
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
// PCIe Host Controller Interface
// =============================================================

/// Data type for bus number.
pub const BusNum = u8;
/// Data type for device number.
pub const DeviceNum = u5;
/// Data type for function number.
pub const FunctionNum = u3;

/// PCIe device address.
pub const DevAddr = struct {
    /// Bus number.
    bus: BusNum = 0,
    /// Device number.
    device: DeviceNum = 0,
    /// Function number.
    function: FunctionNum = 0,
};

/// PCIe host controller.
///
/// Implemented by board-specific PCIe host controller drivers.
pub const Host = struct {
    const Self = @This();

    /// Type-erased pointer to host controller implementation.
    ptr: *anyopaque,
    /// Methods necessary to implement.
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Read a u32 from configuration space.
        readConf: *const fn (ctx: *anyopaque, addr: DevAddr, offset: u12) u32,
        /// Write a u32 to configuration space.
        writeConf: *const fn (ctx: *anyopaque, addr: DevAddr, offset: u12, value: u32) void,
        /// Get the DMA allocator for PCIe devices.
        getDmaAllocator: *const fn (ctx: *anyopaque) common.mem.DmaAllocator,
    };

    /// Get the DMA allocator for PCIe devices.
    pub fn getDmaAllocator(self: Self) common.mem.DmaAllocator {
        return self.vtable.getDmaAllocator(self.ptr);
    }

    /// Get a configuration space accessor for the given device.
    pub fn getIo(self: Self, addr: DevAddr) Io(void) {
        return .{ .host = self, .addr = addr };
    }

    /// Get a typed configuration space accessor for the given device.
    pub fn getTypedIo(self: Self, addr: DevAddr, T: type) Io(T) {
        return .{ .host = self, .addr = addr };
    }

    /// Scan the PCIe bus for devices.
    ///
    /// Scan stops when output buffer is full.
    pub fn scan(self: Self, bus: BusNum, out: []ScanResult) []const ScanResult {
        var n: usize = 0;

        for (0..std.math.maxInt(DeviceNum) + 1) |d| d_block: {
            const device: DeviceNum = @intCast(d);

            for (0..std.math.maxInt(FunctionNum) + 1) |f| f_block: {
                const function: FunctionNum = @intCast(f);
                const addr = DevAddr{ .bus = bus, .device = device, .function = function };
                const io = self.getTypedIo(addr, HeaderType0);

                const vd = io.readReg(HeaderVendorDevice);
                if (vd.vendor_id == 0xFFFF) {
                    if (f == 0) break :f_block;
                    continue;
                }

                const rc = io.readReg(HeaderRevClass);
                out[n] = .{
                    .bus = bus,
                    .device = device,
                    .function = function,
                    .vendor_id = vd.vendor_id,
                    .device_id = vd.device_id,
                    .class = rc.base_class,
                    .subclass = rc.sub_class,
                };

                n += 1;
                if (n >= out.len) break :d_block;

                if (f == 0) {
                    const ht = io.readReg(HeaderBistLatCacheLine);
                    if (ht.header_type & 0x80 == 0) break :f_block;
                }
            }
        }

        return out[0..n];
    }
};

/// Generic ECAM-based PCIe host controller.
///
/// Implements `Host` interface.
pub const EcamHost = struct {
    const Self = @This();

    /// Base virtual address of the ECAM region.
    base: usize,
    /// DMA allocator for PCIe devices.
    dma: DmaAllocatorImpl,

    const vtable = Host.Vtable{
        .readConf = readConfImpl,
        .writeConf = writeConfImpl,
        .getDmaAllocator = getDmaAllocatorImpl,
    };

    /// Initialize the ECAM host controller.
    pub fn init(base: usize, page_allocator: PageAllocator) Self {
        return .{
            .base = base,
            .dma = .new(page_allocator),
        };
    }

    /// Get `Host` interface.
    pub fn interface(self: *Self) Host {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn readConfImpl(ctx: *anyopaque, addr: DevAddr, offset: u12) u32 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return @as(*const volatile u32, @ptrFromInt(self.address(addr, offset))).*;
    }

    fn writeConfImpl(ctx: *anyopaque, addr: DevAddr, offset: u12, value: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        @as(*volatile u32, @ptrFromInt(self.address(addr, offset))).* = value;
    }

    fn getDmaAllocatorImpl(ctx: *anyopaque) common.mem.DmaAllocator {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.dma.interface(0);
    }

    /// Construct the physical address for the given device address.
    inline fn address(self: Self, addr: DevAddr, offset: u12) usize {
        return self.base + bits.concatMany(u28, .{
            addr.bus,
            addr.device,
            addr.function,
            offset,
        });
    }
};

fn Io(Module: type) type {
    return struct {
        const Self = @This();

        /// Host controller interface.
        host: Host,
        /// Target device address.
        addr: DevAddr,

        // =========================================================
        // Raw access

        /// Read a word at the given offset from PCIe configuration space.
        pub fn read(self: Self, offset: u12) u32 {
            return self.host.vtable.readConf(self.host.ptr, self.addr, offset);
        }

        /// Write a word at the given offset to PCIe configuration space.
        pub fn write(self: Self, offset: u12, value: u32) void {
            self.host.vtable.writeConf(self.host.ptr, self.addr, offset, value);
        }

        // =========================================================
        // Typed raw access

        /// Read a register `T` at the given offset from PCIe configuration space.
        pub fn readAs(self: Self, offset: u12, comptime T: type) T {
            return @bitCast(self.read(offset));
        }

        /// Read-modify-write the config space at `offset` using fields of `value`.
        pub fn modifyAs(self: Self, offset: u12, comptime T: type, value: anytype) void {
            var current: T = @bitCast(self.read(offset));
            inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field|
                @field(current, field.name) = @field(value, field.name);
            self.write(offset, @bitCast(current));
        }

        // =========================================================
        // Typed access with Module

        /// Read a register `T` whose offset is determined by `Module`.
        pub fn readReg(self: Self, comptime T: type) T {
            const offset, _ = Module.getRegister(T);
            return @bitCast(self.read(@intCast(offset)));
        }

        /// Read-modify-write a register `T` whose offset is determined by `Module`.
        pub fn modifyReg(self: Self, comptime T: type, value: anytype) void {
            const offset, _ = Module.getRegister(T);
            self.modifyAs(@intCast(offset), T, value);
        }

        // =============================================================
        // BAR

        /// Parse BARs of the device.
        pub fn parseBars(self: Self, out: []BarInfo) []const BarInfo {
            const bar_base, _ = HeaderType0.getRegister(HeaderBar0);

            var out_idx: usize = 0;
            var skip: bool = false;
            for (out, 0..) |*buf, i| {
                if (skip) {
                    skip = false;
                    continue;
                }

                const bar_offset: u12 = @intCast(bar_base + i * @sizeOf(HeaderBar0));
                const value = self.read(bar_offset);

                // Test if BAR is implemented.
                self.write(bar_offset, 0xFFFF_FFFF);
                if (self.read(bar_offset) == 0) {
                    // Unimplemented BAR.
                    continue;
                }
                self.write(bar_offset, value);

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
                    self.write(bar_offset, 0xFFFF_FFFF);
                    const mask = self.read(bar_offset);
                    self.write(bar_offset, value);

                    buf.* = .{
                        .index = i,
                        .type = .mem32,
                        .address = value & mask,
                        .address_mask = bits.concat(u64, @as(u32, 0xFFFF_FFFF), mask),
                    };
                    out_idx += 1;
                } else if (bits.extract(u2, value, 1) == 0x2) {
                    // Memory space BAR (64-bit).
                    const next_value = self.read(bar_offset + 4);
                    self.write(bar_offset, 0xFFFF_FFFF);
                    self.write(bar_offset + 4, 0xFFFF_FFFF);
                    const mask = self.read(bar_offset);
                    const next_mask = self.read(bar_offset + 4);
                    self.write(bar_offset, value);
                    self.write(bar_offset + 4, next_value);

                    const mask64 = bits.concat(u64, next_mask, mask & 0xFFFF_FFF0);
                    const addr64 = bits.concat(u64, next_value, value & 0xFFFF_FFF0) & mask64;

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

        /// Set the address of the BAR.
        ///
        /// This function actually writes to the BAR register.
        pub fn setBarAddress(self: Self, bar: BarInfo, addr: u64) void {
            rtt.expectEqual(0, addr & ~bar.address_mask);

            const bar_base, _ = HeaderType0.getRegister(HeaderBar0);

            switch (bar.type) {
                .io => {
                    @panic("I/O BAR setting not implemented.");
                },
                .mem32 => {
                    const bar_offset: u12 = @intCast(bar_base + bar.index * @sizeOf(HeaderBar0));
                    const value = self.read(bar_offset);
                    self.write(bar_offset, @as(u32, @intCast(addr)) | (value & 0xF));
                },
                .mem64 => {
                    const bar_offset: u12 = @intCast(bar_base + bar.index * @sizeOf(HeaderBar0));
                    const value = self.read(bar_offset);
                    self.write(bar_offset, @as(u32, @intCast(addr)) | (value & 0xF));
                    self.write(bar_offset + 4, @intCast(addr >> 32));
                },
            }
        }
    };
}

/// PCI device found during bus scan.
pub const ScanResult = struct {
    /// Bus number.
    bus: BusNum,
    /// Device number.
    device: DeviceNum,
    /// Function number.
    function: FunctionNum,
    /// Vendor ID.
    vendor_id: u16,
    /// Device ID.
    device_id: u16,
    /// Base class.
    class: u8,
    /// Subclass.
    subclass: u8,
};

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

// =============================================================
// Capability API
// =============================================================

// =========================================================
// Generic

/// PCI Capability IDs.
pub const CapId = enum(u8) {
    /// MSI-X
    msix = 0x11,

    _,
};

/// Generic capability header.
pub const CapHeader = packed struct(u32) {
    /// Capability ID.
    id: CapId,
    /// Next Capability Pointer.
    next: u8,
    /// Capability-specific data.
    _16: u16,
};

/// Find a capability by ID in the configuration space.
///
/// Returns the offset of the capability, or null if not found.
pub fn findCapability(host: Host, addr: DevAddr, cap_id: CapId) ?u8 {
    const io = host.getTypedIo(addr, HeaderType0);
    const status = io.readReg(HeaderCommandStatus);
    if (!status.capabilities_list) return null;

    var offset = io.readReg(HeaderCapPtr).cap_ptr;
    while (offset != 0) {
        const header = io.readAs(offset, CapHeader);
        if (header.id == cap_id) {
            return offset;
        }
        offset = header.next;
    } else return null;
}

// =========================================================
// MSI-X

/// MSI-X Capability Structure.
const MsixCap = packed struct(u32) {
    /// Capability ID.
    id: CapId = .msix,
    /// Next Capability Pointer.
    next: u8,

    /// Table Size - 1.
    table_size: u11,
    /// Reserved.
    _27: u3 = 0,
    /// Global Function Mask.
    function_mask: bool,
    /// MSI-X Enable.
    enabled: bool,
};

/// MSI-X Table Offset/BIR.
const MsixTableOffset = packed struct(u32) {
    /// BAR Indicator Register.
    bir: u3,
    /// Offset within the BAR (8-byte aligned).
    offset: u29,
};

/// MSI-X PBA BIR and Offset.
const MsixPbaOffset = packed struct(u32) {
    /// BAR Indicator Register.
    bir: u3,
    /// Offset within the BAR.
    offset: u29,
};

/// MSI-X Table Entry.
const MsixTableEntry = packed struct(u128) {
    /// Message Address (lower 32 bits).
    msg_addr_lo: u32,
    /// Message Address (upper 32 bits).
    msg_addr_hi: u32,
    /// Message Data.
    msg_data: u32,
    /// Reserved.
    _96: u31 = 0,
    /// Vector Control.
    masked: bool,
};

/// MSI-X configuration.
pub const MsixConfig = struct {
    /// Offset of the MSI-X capability in config space.
    cap_offset: u8,
    /// BAR index containing the MSI-X table.
    table_bar: u3,
    /// Offset of the table within the BAR.
    table_offset: usize,
    /// Table size.
    table_size: u12,
    /// BAR index containing the PBA.
    pba_bar: u3,
    /// Offset of the PBA within the BAR.
    pba_offset: usize,
};

/// Parse MSI-X configuration.
///
/// Returns null if MSI-X capability is not found.
pub fn parseMsixConfig(host: Host, addr: DevAddr) ?MsixConfig {
    const offset = findCapability(host, addr, .msix) orelse return null;
    const io = host.getIo(addr);

    const cap = io.readAs(offset + 0, MsixCap);
    const tbloff = io.readAs(offset + 4, MsixTableOffset);
    const pbaoff = io.readAs(offset + 8, MsixPbaOffset);

    return .{
        .cap_offset = offset,
        .table_bar = tbloff.bir,
        .table_offset = @as(usize, tbloff.offset) << 3,
        .table_size = cap.table_size + 1,
        .pba_bar = pbaoff.bir,
        .pba_offset = @as(usize, pbaoff.offset) << 3,
    };
}

/// Enable MSI-X for the device.
pub fn enableMsix(host: Host, addr: DevAddr, cap_offset: u8) void {
    const io = host.getIo(addr);
    const val = io.read(cap_offset);
    // Set MSI-X Enable bit (bit 31), clear Function Mask (bit 30).
    io.write(cap_offset, (val | (1 << 31)) & ~@as(u32, 1 << 30));
}

/// Disable MSI-X for the device.
pub fn disableMsix(host: Host, addr: DevAddr, cap_offset: u8) void {
    const io = host.getIo(addr);
    const val = io.read(cap_offset);
    // Clear MSI-X Enable bit (bit 31).
    io.write(cap_offset, val & ~@as(u32, 1 << 31));
}

/// Setter for MSI-X Table entry.
pub const MsixTable = struct {
    /// Virtual address of MSI-X table.
    base: usize,

    /// Set MSI-X table entry at the given index.
    pub fn setEntry(self: MsixTable, index: usize, addr: u64, data: u32) void {
        const entry: [*]volatile u32 = @ptrFromInt(self.base);

        entry[index * 4 + 0] = bits.extract(u32, addr, 0);
        entry[index * 4 + 1] = bits.extract(u32, addr, 32);
        entry[index * 4 + 2] = data;
    }

    /// Mask or unmask the MSI-X entry at the given index.
    pub fn maskEntry(self: MsixTable, index: usize, mask: bool) void {
        const entry: [*]volatile u32 = @ptrFromInt(self.base);
        const vec_ctrl = entry[index * 4 + 3];

        entry[index * 4 + 3] = if (mask)
            bits.set(vec_ctrl, 0)
        else
            bits.unset(vec_ctrl, 0);
    }
};

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
    _7: u1 = 0,
    /// SERR# Enable.
    serr_enable: bool,
    /// Fast Back-to-Back Enable.
    fast_back2back_enable: bool,
    /// Interrupt Disable.
    interrupt_disable: bool,
    /// Reserved.
    _11: u5 = 0,

    // =========================================================
    // Status Register

    /// Reserved.
    _16: u3 = 0,
    /// Interrupt Status.
    interrupt_status: bool,
    /// Capabilities List.
    capabilities_list: bool,
    /// 66 MHz Capable.
    _66mhz_capable: bool,
    /// Reserved.
    _22: u1 = 0,
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
    _8: u24,
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
    _30: u2,
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
    _23: u1,
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
    _26: u2,
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
// DMA Allocator
// =============================================================

/// Implements `common.mem.DmaAllocator` using a page allocator.
///
/// Handles the transition between virtual and bus addresses.
pub const DmaAllocatorImpl = struct {
    const Self = @This();

    page_allocator: PageAllocator,

    const vtable = common.mem.DmaAllocator.Vtable{
        .allocPages = Self.allocPages,
        .freePages = Self.freePages,
        .virt2phys = Self.virt2phys,
        .phys2virt = Self.phys2virt,
    };

    pub fn new(page_allocator: PageAllocator) Self {
        return .{ .page_allocator = page_allocator };
    }

    pub fn interface(self: *Self, offset: usize) common.mem.DmaAllocator {
        return common.mem.DmaAllocator{
            .ptr = @ptrCast(self),
            .vtable = &Self.vtable,
            .offset = offset,
        };
    }

    fn allocPages(ctx: *anyopaque, num_pages: usize) common.mem.DmaAllocator.Error![]align(common.mem.DmaAllocator.page_size) u8 {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        return self.page_allocator.allocPagesP(num_pages);
    }

    fn freePages(ctx: *anyopaque, slice: []u8) void {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        self.page_allocator.freePagesP(slice);
    }

    fn virt2phys(ctx: *const anyopaque, vaddr: usize) usize {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        return self.page_allocator.translateP(vaddr);
    }

    fn phys2virt(ctx: *const anyopaque, paddr: usize) usize {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        return self.page_allocator.translateV(paddr);
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.pci);
const common = @import("common");
const PageAllocator = common.mem.PageAllocator;
const bits = common.bits;
const mmio = common.mmio;
const rtt = common.rtt;
