//! EDID: Extended Display Identification Data.

pub const Error = error{
    /// The sum of the block is not zero.
    InvalidChecksum,
} || i2c.Error;

comptime {
    // TODO: layouts are defined for little endian.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

/// Size of an EDID block.
pub const block_size = 128;

// =============================================================
// Block I/O

/// I2C address of the EDID.
const ddc_addr = 0x50;
/// I2C address of the DDC segment pointer.
const segment_addr = 0x30;
/// Size in bytes of a DDC segment.
const segment_size = 256;
/// Number of blocks in a segment.
const blocks_per_segment = segment_size / block_size;

/// Read the EDID block through DDC.
pub fn readBlockI2c(adapter: i2c.Adapter, index: usize) Error![block_size]u8 {
    const segment = std.math.cast(u8, index / blocks_per_segment) orelse {
        return Error.Unsupported;
    };

    var seg = [_]u8{segment};
    var offset = [_]u8{@intCast(index % blocks_per_segment * block_size)};
    var block: [block_size]u8 = undefined;

    // Don't use segment select for segment 0 in case it doesn't support E-DDC.
    const msgs = [_]i2c.Msg{
        .{ .addr = segment_addr, .dir = .write, .buf = &seg },
        .{ .addr = ddc_addr, .dir = .write, .buf = &offset },
        .{ .addr = ddc_addr, .dir = .read, .buf = &block },
    };
    try adapter.xfer(if (segment == 0) msgs[1..] else &msgs);

    // Verify checksum.
    if (sum(&block) != 0) {
        return Error.InvalidChecksum;
    }

    return block;
}

// =============================================================
// Base block

/// Base block.
pub const Base = struct {
    /// Fixed header pattern.
    const header = [8]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };

    layout: *align(1) const BaseLayout,

    /// Parse the given block as EDID base block.
    ///
    /// Returns null if the block is not a valid EDID base block.
    pub fn parse(block: *const [block_size]u8) ?Base {
        const layout: *align(1) const BaseLayout = @ptrCast(block);
        return if (std.mem.eql(u8, &layout.header, &header)) .{
            .layout = layout,
        } else null;
    }

    /// Get the number of extension blocks.
    pub fn extensionCount(self: Base) u8 {
        return self.layout.extension_count;
    }

    /// Get the modes of the detailed timings.
    pub fn modes(self: Base) ModeIterator {
        return .{ .bytes = std.mem.asBytes(&self.layout.descriptors) };
    }
};

/// Layout of the EDID base block.
const BaseLayout = extern struct {
    /// Constant fixed pattern.
    header: [8]u8,
    /// Manufacturer ID encoded in 2 bytes.
    manufacturer: [2]u8,
    /// Product ID code.
    product_code: u16,
    /// Serial number.
    serial: u32,
    /// Week of manufacture.
    week: u8,
    /// Year of manufacture.
    year: u8,
    /// EDID version number.
    version: u8,
    /// EDID revision number.
    revision: u8,
    /// Video input type.
    input: u8,
    /// Horizontal size of the display in centimeters.
    width_cm: u8,
    /// Vertical size of the display in centimeters.
    height_cm: u8,
    /// Display gamma.
    gamma: u8,
    /// Feature support flags.
    features: u8,
    /// Chromaticity coordinates.
    chromaticity: [10]u8,
    /// EDID standard established timings.
    established: [3]u8,
    /// Manufacturer reserved timings.
    standard: [8][2]u8,
    /// Detailed timings or display descriptors.
    descriptors: [4][DtdLayout.size]u8,
    /// Number of extension blocks.
    extension_count: u8,
    /// Checksum.
    checksum: u8,

    comptime {
        std.debug.assert(@sizeOf(@This()) == block_size);
    }
};

/// Parse the DTD to construct a video mode.
///
/// Returns null if the descriptor is not a DTD or the descriptor is not supported.
fn parseDtd(bytes: *const [DtdLayout.size]u8) ?Mode {
    const d: *align(1) const DtdLayout = @ptrCast(bytes);
    // Not valid descriptor.
    if (d.pixel_clock == 0) {
        return null;
    }
    // Digital separate sync is not supported.
    if (d.sync_type != .digital_separate) {
        return null;
    }

    const hactive = join(d.hactive_hi, d.hactive_lo);
    const hsync_offset = join(d.hsync_offset_hi, d.hsync_offset_lo);
    const hsync_width = join(d.hsync_width_hi, d.hsync_width_lo);
    const vactive = join(d.vactive_hi, d.vactive_lo);
    const vsync_offset = join(d.vsync_offset_hi, d.vsync_offset_lo);
    const vsync_width = join(d.vsync_width_hi, d.vsync_width_lo);

    var mode: Mode = .{
        .clock = @as(u32, d.pixel_clock) * 10,
        .vic = 0,
        .aspect = .none,
        .hdisplay = hactive,
        .hsync_start = hactive + hsync_offset,
        .hsync_end = hactive + hsync_offset + hsync_width,
        .htotal = hactive + join(d.hblank_hi, d.hblank_lo),
        .hsync_pos = d.hsync_pos,
        .vdisplay = vactive,
        .vsync_start = vactive + vsync_offset,
        .vsync_end = vactive + vsync_offset + vsync_width,
        .vtotal = vactive + join(d.vblank_hi, d.vblank_lo),
        .vsync_pos = d.vsync_pos,
        .interlaced = d.interlaced,
    };
    mode.fillCtaInfo();
    return mode;
}

/// Join the upper bits and the lower 8 bits.
inline fn join(hi: anytype, lo: u8) u16 {
    return (@as(u16, hi) << @bitSizeOf(u8)) | lo;
}

/// Detailed timing descriptor layout.
const DtdLayout = packed struct(u144) {
    const size = @bitSizeOf(DtdLayout) / @bitSizeOf(u8);

    /// Pixel clock in 10 kHz.
    ///
    /// If zero, reserved and not a DTD.
    pixel_clock: u16,
    /// Horizontal active pixels lower bits.
    hactive_lo: u8,
    /// Horizontal blanking pixels lower bits.
    hblank_lo: u8,
    /// Horizontal blanking pixels upper bits.
    hblank_hi: u4,
    /// Horizontal active pixels upper bits.
    hactive_hi: u4,
    /// Vertical active lines lower bits.
    vactive_lo: u8,
    /// Vertical blanking lines lower bits.
    vblank_lo: u8,
    /// Vertical blanking lines upper bits.
    vblank_hi: u4,
    /// Vertical active lines upper bits.
    vactive_hi: u4,
    /// Horizontal sync front porch pixels lower bits.
    hsync_offset_lo: u8,
    /// Horizontal sync pulse width pixels lower bits.
    hsync_width_lo: u8,
    /// Vertical sync pulse width pixels lower bits.
    vsync_width_lo: u4,
    /// Vertical sync front porch pixels lower bits.
    vsync_offset_lo: u4,
    /// Vertical sync pulse width pixels upper bits.
    vsync_width_hi: u2,
    /// Vertical sync front porch pixels upper bits.
    vsync_offset_hi: u2,
    /// Horizontal sync pulse width pixels upper bits.
    hsync_width_hi: u2,
    /// Horizontal sync front porch pixels upper bits.
    hsync_offset_hi: u2,
    /// Horizontal image size lower bits.
    hsize_lo: u8,
    /// Vertical image size lower bits.
    vsize_lo: u8,
    /// Vertical image size upper bits.
    vsize_hi: u4,
    /// Horizontal image size upper bits.
    hsize_hi: u4,
    /// Horizontal border pixels.
    hborder: u8,
    /// Vertical border lines.
    vborder: u8,
    /// Stereo mode lower bits.
    stereo_lo: bool,
    /// Polarity of the horizontal sync is positive.
    ///
    /// Valid only for the digital separate sync.
    hsync_pos: bool,
    /// Polarity of the vertical sync is positive.
    ///
    /// Valid only for the digital separate sync.
    vsync_pos: bool,
    /// Sync signal type.
    sync_type: enum(u2) {
        /// Analogue composite sync.
        analog_composite = 0,
        /// Analogue sync with both polarities.
        bipolar_analog_composite = 1,
        /// Digital sync with horizontal and vertical signals in the same line.
        digital_composite = 2,
        /// Digital sync with separate horizontal and vertical signals.
        digital_separate = 3,
    },
    /// Stereo mode upper bits.
    stereo_hi: u2,
    /// Interlaced.
    interlaced: bool,
};

/// Iterator over the video mode derived from DTDs.
pub const ModeIterator = struct {
    /// Bytes of the descriptors.
    bytes: []const u8,
    /// Current position.
    pos: usize = 0,

    /// Get the next detailed timing.
    ///
    /// Descriptors other than DTD are skipped.
    pub fn next(self: *ModeIterator) ?Mode {
        while (self.pos + DtdLayout.size <= self.bytes.len) {
            const d = self.bytes[self.pos..][0..DtdLayout.size];
            self.pos += DtdLayout.size;
            if (parseDtd(d)) |m| return m;
        } else return null;
    }
};

// =============================================================
// CTA-861 extension block

/// CTA-861 extension block.
pub const Cta = struct {
    /// Tag of the CTA extension block.
    const block_tag = 0x02;
    /// Minimum revision supported.
    const min_revision = 3;

    /// OUI of HDMI Licensing in the VSDB, in little endian.
    const hdmi_oui = [3]u8{ 0x03, 0x0C, 0x00 };

    layout: *align(1) const CtaLayout,

    /// Data block tag.
    pub const Tag = enum(u3) {
        /// Audio (ADB, containing SADs)
        audio = 1,
        /// Video (VDB, containing SVDs)
        video = 2,
        /// Vendor-specific (VSDB)
        vendor = 3,
        /// Speaker Allocation (SADB)
        speaker = 4,
        /// VESA Display Transfer Characteristic (VESA DTCDB)
        vesa = 5,
        /// Video Format (VFDB)
        video_format = 6,
        /// Use extended tag.
        extended = 7,

        _,
    };

    /// Extended data block tag.
    pub const ExtTag = enum(u8) {
        /// Video capability (VCDB)
        video_capability = 0,

        _,
    };

    /// Data block.
    pub const DataBlock = struct {
        /// Data block tag.
        tag: Tag,
        /// Valid only for the extended data block.
        ext_tag: ExtTag,
        /// Payload excluding the header and the extended tag.
        payload: []const u8,
    };

    /// Layout of header of the data block.
    const DataBlockHeader = packed struct(u8) {
        /// Length of the payload.
        len: u5,
        /// Data block tag.
        tag: Tag,
    };

    /// Short Video Descriptor in the video data block.
    pub const Svd = packed struct(u8) {
        low: u7,
        high: bool,

        /// Video Identification Code.
        pub fn vic(self: Svd) u8 {
            const raw: u8 = @bitCast(self);
            return if (self.isNative()) raw - 128 else raw;
        }

        /// Whether the format is the native one.
        pub fn isNative(self: Svd) bool {
            const raw: u8 = @bitCast(self);
            return 129 <= raw and raw <= 192;
        }
    };

    /// Iterator over the data blocks.
    pub const DataBlockIterator = struct {
        /// Bytes of the data blocks.
        bytes: []const u8,
        /// Current position.
        pos: usize = 0,

        /// Get the next data block.
        pub fn next(self: *DataBlockIterator) ?DataBlock {
            while (self.pos < self.bytes.len) {
                const hdr: DataBlockHeader = @bitCast(self.bytes[self.pos]);
                if (self.pos + @sizeOf(DataBlockHeader) + hdr.len > self.bytes.len) {
                    return null;
                }

                const payload = self.bytes[self.pos + 1 ..][0..hdr.len];
                self.pos += @sizeOf(DataBlockHeader) + hdr.len;

                // Non-extended data block.
                if (hdr.tag != .extended) return .{
                    .tag = hdr.tag,
                    .ext_tag = undefined,
                    .payload = payload,
                };
                // Empty data block.
                if (hdr.len == 0) {
                    continue;
                }
                // Extended data block.
                return .{
                    .tag = hdr.tag,
                    .ext_tag = @fromBackingInt(@intCast(payload[0])),
                    .payload = payload[1..],
                };
            }
            return null;
        }
    };

    /// Parse the given block as a CTA-861 extension block.
    ///
    /// Returns null if the block is not a supported CTA-861 extension block.
    pub fn parse(block: *const [block_size]u8) ?Cta {
        const layout: *align(1) const CtaLayout = @ptrCast(block);
        if (layout.tag != block_tag or layout.revision < min_revision) return null;
        return .{ .layout = layout };
    }

    /// Get the data blocks.
    pub fn dataBlocks(self: Cta) DataBlockIterator {
        return .{ .bytes = self.layout.data[0..self.dtdStart()] };
    }

    /// Get the modes of the detailed timings.
    pub fn modes(self: Cta) ModeIterator {
        return .{ .bytes = self.layout.data[self.dtdStart()..] };
    }

    /// Check if the sink supports the given Video Identification Code.
    pub fn hasVic(self: Cta, vic: u8) bool {
        return self.findSvd(vic) != null;
    }

    /// Find the SVD of the given Video Identification Code.
    pub fn findSvd(self: Cta, vic: u8) ?Svd {
        var it = self.dataBlocks();
        while (it.next()) |b| {
            if (b.tag != .video) continue;
            for (b.payload) |code| {
                const svd: Svd = @bitCast(code);
                if (svd.vic() == vic) return svd;
            }
        } else return null;
    }

    /// Check if the sink is an HDMI sink.
    pub fn isHdmi(self: Cta) bool {
        var it = self.dataBlocks();
        while (it.next()) |b| {
            if (b.tag == .vendor and
                b.payload.len >= hdmi_oui.len and
                std.mem.eql(u8, b.payload[0..hdmi_oui.len], &hdmi_oui))
            {
                return true;
            }
        } else return false;
    }

    /// Get the end of the data blocks (the start of the detailed timings).
    ///
    /// The offset is relative to the data section.
    fn dtdStart(self: Cta) usize {
        const offset = self.layout.dtd_offset;
        if (offset == 0) return CtaLayout.data_size; // No DTD available
        return @min(offset -| CtaLayout.data_start, CtaLayout.data_size);
    }
};

/// Layout of the CTA-861 extension block.
const CtaLayout = extern struct {
    /// Extension tag.
    tag: u8,
    /// Revision number.
    revision: u8,
    /// Offset of the first detailed timing from the beginning of the block.
    dtd_offset: u8,
    /// Flags.
    flags: u8,
    /// Data blocks, detailed timings and the padding.
    data: [data_size]u8,
    /// Checksum.
    checksum: u8,

    /// Offset of the data in the block.
    const data_start = 4;
    /// Size in bytes of the data field.
    const data_size = block_size - data_start - 1; // -1 for checksum

    comptime {
        std.debug.assert(@offsetOf(CtaLayout, "data") == data_start);
        std.debug.assert(@sizeOf(CtaLayout) == block_size);
    }
};

/// Calculate the sum of bytes.
fn sum(block: []const u8) u8 {
    var s: u8 = 0;
    for (block) |b| s +%= b;
    return s;
}

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

fn hexBlock(comptime hex: []const u8) [block_size]u8 {
    var block: [block_size]u8 = undefined;
    _ = std.fmt.hexToBytes(&block, hex) catch unreachable;
    return block;
}

const test_base = hexBlock("00FFFFFFFFFFFF004A8B3400120000000A20010380160F782AEE91A3544C99260F5054210800810081C081809500A9C0B300D1C00101984080A070002D5030204500DE940000001E000000FC0048444D490A2020202020202020000000FF000A202020202020202020202020000000FD00303F1E6414000A202020202020018A");
const test_cta = hexBlock("020333F2479001020304131FE200D5E305C00023097F078301000067030C0010001848E6060501626200681A00000101303CE6023A801871382D40582C4500DE940000001E0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000079");

test "checksum of the sample blocks" {
    try testing.expectEqual(0, sum(&test_base));
    try testing.expectEqual(0, sum(&test_cta));
}

test "base block" {
    const base = Base.parse(&test_base).?;
    try testing.expectEqual(1, base.extensionCount());
}

test "parse rejects the block of the other kind" {
    try testing.expectEqual(null, Base.parse(&test_cta));
    try testing.expectEqual(null, Cta.parse(&test_base));
}

test "base block detailed timings" {
    var it = Base.parse(&test_base).?.modes();
    const t = it.next().?;
    try testing.expectEqual(165_360, t.clock);
    try testing.expectEqual(1920, t.hdisplay);
    try testing.expectEqual(2080, t.htotal);
    try testing.expectEqual(1280, t.vdisplay);
    try testing.expectEqual(1325, t.vtotal);
    try testing.expectEqual(null, it.next());
}

test "CTA detailed timings" {
    const cta = Cta.parse(&test_cta).?;
    var it = cta.modes();
    const t = it.next().?;
    try testing.expectEqual(148_500, t.clock);
    try testing.expectEqual(1920, t.hdisplay);
    try testing.expectEqual(2008, t.hsync_start);
    try testing.expectEqual(2052, t.hsync_end);
    try testing.expectEqual(2200, t.htotal);
    try testing.expectEqual(true, t.hsync_pos);
    try testing.expectEqual(1080, t.vdisplay);
    try testing.expectEqual(1084, t.vsync_start);
    try testing.expectEqual(1089, t.vsync_end);
    try testing.expectEqual(1125, t.vtotal);
    try testing.expectEqual(true, t.vsync_pos);
    try testing.expectEqual(false, t.interlaced);
}

test "CTA data blocks" {
    const cta = Cta.parse(&test_cta).?;
    try testing.expectEqual(true, cta.hasVic(16));
    try testing.expectEqual(true, cta.hasVic(1));
    try testing.expectEqual(false, cta.hasVic(5));
    try testing.expectEqual(true, cta.isHdmi());
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const builtin = @import("builtin");
const dd = @import("dd");
const i2c = dd.i2c;
const Mode = @import("Mode.zig");
