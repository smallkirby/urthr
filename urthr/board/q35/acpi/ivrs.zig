//! AMD I/O Virtualization Reporting Structure.
//!
//! ref. AMD I/O Virtualization Technology (IOMMU) Specification, 48882-PUB—Rev 3.11—Apr 2026

/// AMD I/O Virtualization Reporting Structure.
pub const Ivrs = struct {
    /// SDT header.
    header: SdtHeader,
};

/// IVRS header following immediately after the SDT header.
const IvrsHeader = extern struct {
    /// I/O virtualization information common to all IOMMU units.
    ivinfo: IvInfo,
    /// Reserved.
    _rsvd: [8]u8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(IvrsHeader) == 12);
    }
};

const IvInfo = packed struct(u32) {
    /// Extended Feature Support.
    efr: bool,
    /// The IOMMU is used for Pre-Boot DMA protection,
    /// and device accessed memory should be remapped after the OS has loaded.
    dma_remap: bool,
    /// Reserved.
    _2: u3 = 0,
    /// Guest virtual address width.
    gva_size: GvaSize,
    /// System physical address width.
    pa_size: PaSize,
    /// Virtual address width.
    va_size: VaSize,
    /// ATS response address range reserved.
    ht_ats_resv: bool,
    /// Reserved.
    _23: u9 = 0,
};

/// Guest virtual address width.
const GvaSize = enum(u3) {
    /// 48-bits.
    @"48" = 0b010,
    /// 57-bits.
    @"57" = 0b011,

    _,
};

/// System physical address size.
const PaSize = enum(u7) {
    /// 40-bits.
    @"40" = 0b010_1000,
    /// 48-bits.
    @"48" = 0b011_0000,
    /// 52-bits.
    @"52" = 0b011_0100,

    _,
};

/// Virtual address size.
const VaSize = enum(u7) {
    /// 32-bits.
    @"32" = 0b010_0000,
    /// 40-bits.
    @"40" = 0b010_1000,
    /// 48-bits.
    @"48" = 0b011_0000,
    /// 64-bits.
    @"64" = 0b100_0000,

    _,
};

/// IVRS revision.
const Revision = enum(u8) {
    /// This format only supports pre-assigned DeviceIDs.
    fixed = 1,
    /// This format supports both pre-assigned DeviceIDs and ACPI HID device naming.
    mixed = 2,

    _,
};

/// I/O Virtualization Device Block iterator.
///
/// IVDBs are IVHD or IVMD blocks.
const IvdbIter = struct {
    cur: usize,
    end: usize,

    /// Header common to all IVDBs.
    const Header = extern struct {
        /// Type of IVDB.
        type: IvdbType,
        /// Opaque type for flags.
        flags: u8,
        /// Length of the IVDB in bytes, including this header.
        length: u16,
    };

    /// IVDB block descriptor.
    pub const Block = struct {
        /// Type of IVDB.
        type: IvdbType,
        /// Bytes of entire block including the header.
        bytes: []const u8,
    };

    pub fn init(addr: usize, size: usize) IvdbIter {
        return .{ .cur = addr, .end = addr + size };
    }

    /// Get the next block.
    ///
    /// Returns null if there are no more blocks or the remaining area is malformed.
    pub fn next(self: *IvdbIter) ?Block {
        const remain = self.end - self.cur;
        if (remain < @sizeOf(Header)) return null;

        const header: *align(1) const Header = @ptrFromInt(self.cur);
        const length: usize = header.length;
        if (length < @sizeOf(Header) or length > remain) {
            log.warn("Malformed IVDB: type={}, length={d}", .{ header.type, length });
            self.cur = self.end;
            return null;
        }

        defer self.cur += length;
        return .{
            .type = header.type,
            .bytes = @as([*]const u8, @ptrFromInt(self.cur))[0..length],
        };
    }
};

/// Device entry iterator for an IVHD block.
const DeviceEntryIter = struct {
    rest: []const u8,

    /// Device entry descriptor.
    pub const Entry = struct {
        /// Type of the device entry.
        type: DeviceEntry.Type,
        /// DeviceID field.
        devid: u16,
        /// Entire entry including the type field.
        bytes: []const u8,
    };

    /// Create an iterator over the device entries.
    pub fn init(entries: []const u8) DeviceEntryIter {
        return .{ .rest = entries };
    }

    /// Get the next device entry.
    ///
    /// Returns null if there are no more entries or an unsupported entry is found.
    pub fn next(self: *DeviceEntryIter) ?Entry {
        if (self.rest.len < 4) return null;

        const typ: DeviceEntry.Type = @fromBackingInt(self.rest[0]);
        const size = typ.size() orelse {
            log.warn("Unsupported IVHD device entry: type=0x{X:0>2}", .{self.rest[0]});
            self.rest = &.{};
            return null;
        };
        if (size > self.rest.len) {
            log.warn("Truncated IVHD device entry: type=0x{X:0>2}", .{self.rest[0]});
            self.rest = &.{};
            return null;
        }

        defer self.rest = self.rest[size..];
        return .{
            .type = typ,
            .devid = std.mem.readInt(u16, self.rest[1..3], .little),
            .bytes = self.rest[0..size],
        };
    }
};

/// I/O Virtualization Hardware Definition block.
///
/// Each IOMMU in the system is described by one IVHD block.
/// An IOMMU and the peripherals must be on the same PCI Segment defined in the IVHD block.
const Ivhd = struct {
    /// IVHD block type.
    type: IvdbType,
    /// Settings for selected IOMMU control fields.
    flags: Flags,
    /// DeviceID of IOMMU.
    deviceid: u16,
    /// Offset in Capability space for control fields of IOMMU.
    cap_offset: u16,
    /// Base address of IOMMU control registers in MMIO space.
    base: u64,
    /// PCI Segment Group number.
    seg_group: u16,
    /// Interrupt numbers and UnitID.
    info: Info,
    /// Exact copy of Extended Feature Register.
    efr_image: ?u64,
    /// Device entries following the IVHD header.
    entries: []const u8,

    /// Parse an IVHD block.
    ///
    /// Returns null if the block is not an IVHD or is shorter than its header.
    pub fn from(block: IvdbIter.Block) ?Ivhd {
        switch (block.type) {
            inline .ivhd10, .ivhd11, .ivhd40 => |t| {
                const T = switch (t) {
                    .ivhd10 => T10,
                    .ivhd11 => T11,
                    .ivhd40 => T40,
                    else => unreachable,
                };
                if (block.bytes.len < @sizeOf(T)) return null;

                const h: *align(1) const T = @ptrCast(block.bytes.ptr);
                return .{
                    .type = h.type,
                    .flags = h.flags,
                    .deviceid = h.deviceid,
                    .cap_offset = h.cap_offset,
                    .base = h.base,
                    .seg_group = h.seg_group,
                    .info = h.info,
                    .efr_image = if (T == T10) null else h.efr_image,
                    .entries = block.bytes[@sizeOf(T)..],
                };
            },
            else => return null,
        }
    }

    /// Type 10h.
    const T10 = extern struct {
        /// IVHD block type.
        type: IvdbType = .ivhd10,
        /// Settings for selected IOMMU control fields.
        flags: Flags,
        /// Size of IVHD block in bytes, starting from `type` field and including IVHD device entries.
        length: u16,
        /// DeviceID of IOMMU.
        deviceid: u16,
        /// Offset in Capability space for control fields of IOMMU.
        cap_offset: u16,
        /// Base address of IOMMU control registers in MMIO space.
        base: u64,
        /// PCI Segment Group number.
        seg_group: u16,
        /// Interrupt numbers and UnitID.
        info: Info,
        /// IOMMU Feature Reporting.
        feature: FeatReport,
    };

    /// Type 11h.
    const T11 = extern struct {
        /// IVHD block type.
        type: IvdbType = .ivhd11,
        /// Recommended settings for selected IOMMU control fields.
        flags: Flags,
        /// Size of IVHD block in bytes, starting from `type` field and including IVHD device entries.
        length: u16,
        /// DeviceID of IOMMU.
        deviceid: u16,
        /// Offset in Capability space for control fields of IOMMU.
        cap_offset: u16,
        /// Base address of IOMMU control registers in MMIO space.
        base: u64,
        /// PCI Segment Group number.
        seg_group: u16 = 0,
        /// Interrupt numbers and UnitID.
        info: Info,
        /// IOMMU information not reported in the Extended Feature Register.
        attr: Attr,
        /// Exact copy of Extended Feature Register.
        efr_image: u64,
        /// Reserved.
        _32: u64 = 0,
    };

    /// Type 40h.
    const T40 = extern struct {
        /// IVHD block type.
        type: IvdbType = .ivhd40,
        /// Recommended settings for selected IOMMU control fields.
        flags: Flags,
        /// Size of IVHD block in bytes, starting from `type` field and including IVHD device entries.
        length: u16,
        /// DeviceID of IOMMU.
        deviceid: u16,
        /// Offset in Capability space for control fields of IOMMU.
        cap_offset: u16,
        /// Base address of IOMMU control registers in MMIO space.
        base: u64,
        /// PCI Segment Group number.
        seg_group: u16 = 0,
        /// Interrupt numbers and UnitID.
        info: Info,
        /// IOMMU information not reported in the Extended Feature Register.
        attr: Attr,
        /// Exact copy of Extended Feature Register.
        efr_image: u64,
        /// Exact copy of Extended Feature 2 Register.
        efr_image2: u64,
    };

    /// IVHD flags.
    const Flags = packed struct(u8) {
        /// Recommended setting for HtTunEn.
        ht_tun_en: bool,
        /// Recommended setting for PassPW.
        pass_pw: bool,
        /// Recommended setting for ResPassPW.
        res_pass_pw: bool,
        /// Recommended setting for Isoc control bit.
        isoc: bool,
        /// Defines remote IOTLB support.
        iotlb_sup: bool,
        /// Recommended setting for Coherent control bit.
        coherent: bool,
        /// Defines PREFETCH_IOMMU_PAGES support.
        pre_fsup: bool,
        /// Defines peripheral page service support.
        ppr_sup: bool,
    };

    /// IOMMU information.
    const Info = packed struct(u16) {
        /// MSI message number for event log.
        ms_inum: u5,
        /// Reserved.
        _5: u3 = 0,
        /// Unit ID number.
        unit_id: u5,
        /// Reserved.
        _13: u3 = 0,
    };

    /// IOMMU Feature Reporting.
    const FeatReport = packed struct(u32) {
        /// x2APIC supported for peripherals.
        xt_sup: bool,
        /// NX supported for I/O.
        nx_sup: bool,
        /// Guest translation supported.
        gt_sup: bool,
        /// Number of guest CR3 tables supported.
        glx_sup: u2,
        /// INVALIDATE_IOMMU_ALL supported.
        ia_sup: bool,
        /// Guest virtual APIC supported.
        ga_sup: bool,
        /// Hardware Error Registers supported.
        he_sup: bool,
        /// Parameter that indicates the maximum PASID value supported by the IOMMU.
        pas_max: u5,
        /// Number of performance counters per counter bank.
        pn_counters: u4,
        /// Number of performance counter banks.
        pn_banks: u6,
        /// MsiNumPPR for peripheral page requests.
        msi_num_ppr: u5,
        /// Guest address translation size.
        gats: u2,
        /// Host address translation size.
        hats: u2,
    };

    const Attr = packed struct(u32) {
        /// Host Address Translation Disable.
        hat_dis: bool,
        /// Reserved.
        _1: u12 = 0,
        /// Number of performance counters per counter bank.
        pn_counters: u4,
        /// Number of performance counter banks.
        pn_banks: u6,
        /// MsiNumPPR for peripheral page requests.
        msi_num_ppr: u5,
        /// Reserved.
        _28: u4 = 0,
    };
};

const DeviceEntry = struct {
    /// Device entry type code.
    const Type = enum(u8) {
        /// DTE setting applies to all DeviceIDs controlled by the IOMMU.
        all = 0x01,
        /// DTE setting applies to the device specified in DevID field.
        select = 0x02,
        /// DTE setting applies to all devices from start of range specified by the DevID field of this entry,
        /// to the DeviceID specified by the DevID field of the subsequent type 4 device entry.
        range_start = 0x03,
        /// See `range_end`.
        range_end = 0x04,

        /// DTE setting applies to device specified by DevIDa.
        alias_select = 0x42,
        /// DTE setting applies to all peripherals from start of range.
        /// All peripherals in range use DevIDb as source identicification information.
        alias_range_start = 0x43,
        /// DTE and extended DTE setting apply to device specified by DevID.
        ext_select = 0x46,
        /// DTE and extended DTE setting apply to all devices starting from the device specified by DevID.
        /// Range is terminated with an type 4 entry.
        ext_range_start = 0x47,
        /// Special device (IOAPIC or HPET).
        special = 0x48,

        _,

        /// Get the length of the device entry of this type in bytes.
        ///
        /// Returns null for variable length entries.
        pub fn size(self: Type) ?usize {
            return switch (@backingInt(self) >> 6) {
                0b00 => 4,
                0b01 => 8,
                else => null,
            };
        }
    };

    const Setting = packed struct(u8) {
        /// Device able to assert INIT interrupts.
        init_pass: bool,
        /// Device able to assert ExtInt interrupts.
        eint_pass: bool,
        /// Device able to assert NMI interrupts.
        nmi_pass: bool,
        /// ATC is available on the device and use of ATS are permitted for the device.
        atc_permit: bool,
        /// Device able to assert System Management messages.
        sys_mgt: bool,
        /// Device able to assert LINT0 interrupts.
        lint0pass: bool,
        /// Device able to assert LINT1 interrupts.
        lint1pass: bool,
    };

    const ExtSetting = packed struct(u32) {
        /// Device features CXL.cache interface.
        cxl_device: u3,
        /// Reserved.
        _3: u28 = 0,
        /// Device must be prevented from issuing address translation requests.
        ats_disabled: bool,
    };
};

/// IVDB block type.
const IvdbType = enum(u8) {
    /// IVHD block type 0x10h.
    ///
    /// For backward compatibility and supports the reporting of legacy IOMMU properties.
    ivhd10 = 0x10,
    /// IVHD block type 0x11h.
    ///
    /// Contains all relevant IOMMU feature information.
    /// SW is recommended to detect IOMMU features from the fields in IVHD Type 11h structure.
    ivhd11 = 0x11,
    /// IVHD block type 0x40h.
    ///
    /// Adds support for ACPI HID device entries.
    ivhd40 = 0x40,

    /// IVMD block type 0x20h.
    ivmd20 = 0x20,
    /// IVMD block type 0x21h.
    ivmd21 = 0x21,
    /// IVMD block type 0x22h.
    ivmd22 = 0x22,

    _,
};

/// Parse IVRS structure pointed to by the given physical address.
pub fn parse(phys: usize, allocator: PageAllocator) PageAllocator.Error!?Ivrs {
    const virt = allocator.translateV(phys);
    var header: SdtHeader = undefined;
    @memcpy(
        std.mem.asBytes(&header)[0..SdtHeader.size()],
        @as([*]const u8, @ptrFromInt(virt))[0..SdtHeader.size()],
    );

    // Validate SDT header.
    if (!header.is(.ivrs)) {
        log.err("Invalid IVRS signature.", .{});
        return null;
    }
    if (header.calcSum(virt) != 0) {
        log.err("Invalid IVRS checksum.", .{});
        return null;
    }

    const revision: Revision = @fromBackingInt(@intCast(header.revision));
    const ivheader: *align(1) const IvrsHeader = @ptrFromInt(virt + SdtHeader.size());
    const ivinfo = ivheader.ivinfo;
    log.debug("Revision: {}", .{revision});
    log.debug("DMA remap: {}, PA: {}, VA: {}, EFR: {}", .{
        ivinfo.dma_remap, ivinfo.pa_size, ivinfo.va_size, ivinfo.efr,
    });

    // Parse IVDBs.
    const ivdb_offset = SdtHeader.size() + @sizeOf(IvrsHeader);
    if (header.length < ivdb_offset) {
        log.err("Invalid IVRS length: {d}", .{header.length});
        return null;
    }

    var iter = IvdbIter.init(virt + ivdb_offset, header.length - ivdb_offset);
    while (iter.next()) |block| {
        if (Ivhd.from(block)) |ivhd| {
            // Parse as IVHD.
            log.debug("IVHD {}: DevID=0x{X:0>4}, cap=0x{X}, base=0x{X}, EFR={?X}", .{
                ivhd.type, ivhd.deviceid, ivhd.cap_offset, ivhd.base, ivhd.efr_image,
            });

            // Parse device entries.
            var entries = DeviceEntryIter.init(ivhd.entries);
            while (entries.next()) |entry| {
                log.debug("  {} DevID=0x{X:0>4}", .{
                    entry.type, entry.devid,
                });
            }
        } else {
            log.warn("Skipping non-IVHD IVDB.", .{});
            continue;
        }
    }

    return .{ .header = header };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.ivrs);
const common = @import("common");
const PageAllocator = common.mem.PageAllocator;
const sdt = @import("sdt.zig");
const SdtHeader = sdt.SdtHeader;
