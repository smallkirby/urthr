//! HDMI common definition.

/// Size of the InfoFrame header including the checksum.
pub const header_size = 4;

/// InfoFrame packet type.
pub const InfoFrameType = enum(u8) {
    /// Vendor-specific.
    vendor = 0x81,
    /// Auxiliary Video Information.
    avi = 0x82,
    /// Source Product Description.
    spd = 0x83,
    /// Audio.
    audio = 0x84,
};

/// Colorspace.
pub const Colorspace = enum(u2) {
    /// RGB.
    rgb = 0,
    /// YUV422
    yuv422 = 1,
    /// YUV444
    yuv444 = 2,
    /// YUV420
    yuv420 = 3,
};

/// Scan information.
pub const ScanMode = enum(u2) {
    /// No data.
    none = 0,
    /// Overscan. Can cut off edges of the picture.
    overscan = 1,
    /// Underscan. Don't cut off edges of the picture.
    underscan = 2,
};

/// Colorimetry.
pub const Colorimetry = enum(u2) {
    /// No information.
    none = 0,
    /// ITU-R BT.601.
    itu601 = 1,
    /// ITU-R BT.709.
    itu709 = 2,
    /// Extended colorimetry.
    extended = 3,
};

/// Picture aspect ratio.
pub const PictureAspect = enum(u2) {
    /// No information.
    none = 0,
    /// 4:3
    @"4:3" = 1,
    /// 16:9
    @"16:9" = 2,
};

/// Active format aspect ratio.
pub const ActiveAspect = enum(u4) {
    /// No information.
    none = 0,
    /// Same as the entire picture aspect ratio.
    picture = 8,

    _,
};

/// RGB quantization range.
pub const QuantizationRange = enum(u2) {
    /// Default range.
    default = 0,
    /// Limited range.
    limited = 1,
    /// Full range.
    full = 2,
};

/// Scaling information.
pub const Nups = enum(u2) {
    /// No known non-uniform scaling.
    unknown = 0,
    /// Horizontal scaling.
    horizontal = 1,
    /// Vertical scaling.
    vertical = 2,
    /// Both horizontal and vertical scaling.
    both = 3,
};

/// YCC quantization range.
pub const YccQuantizationRange = enum(u2) {
    /// Limited range.
    limited = 0,
    /// Full range.
    full = 1,
};

/// Content type.
pub const ContentType = enum(u2) {
    /// Graphics content.
    graphics = 0,
    /// Photo content.
    photo = 1,
    /// Cinema content.
    cinema = 2,
    /// Game content.
    game = 3,
};

/// AVI InfoFrame version 2.
pub const Avi = struct {
    /// Size of the InfoFrame including the header.
    pub const size = header_size + data_length;
    /// Version of the InfoFrame.
    const version = 2;
    /// Length of the data bytes.
    const data_length = 13;

    /// Color space.
    colorspace: Colorspace = .rgb,
    /// Top bar data.
    top_bar: u16 = 0,
    /// Bottom bar data.
    bottom_bar: u16 = 0,
    /// Left bar data.
    left_bar: u16 = 0,
    /// Right bar data.
    right_bar: u16 = 0,
    /// Scan information.
    scan_mode: ScanMode = .none,

    /// Colorimetry.
    colorimetry: Colorimetry = .none,
    /// Picture aspect ratio.
    picture_aspect: PictureAspect = .none,
    /// Active format aspect ratio.
    active_aspect: ActiveAspect = .none,

    /// IT content.
    itc: bool = false,
    /// Extended colorimetry.
    extended_colorimetry: u3 = 0,
    /// Quantization range.
    quantization_range: QuantizationRange = .default,
    /// Scaling information.
    nups: Nups = .unknown,

    /// Video Identification Code.
    video_code: u7 = 0,

    /// YCC quantization range.
    ycc_quantization_range: YccQuantizationRange = .limited,
    /// Content type.
    content_type: ContentType = .graphics,
    /// Pixel repetition factor.
    pixel_repeat: u4 = 0,

    /// Pack the InfoFrame into the binary representation with the header and the checksum.
    pub fn pack(self: Avi) [size]u8 {
        var buffer = std.mem.zeroes([size]u8);

        // Header bytes.
        buffer[0] = @backingInt(InfoFrameType.avi);
        buffer[1] = version;
        buffer[2] = data_length;

        // Data bytes.
        const data = buffer[header_size..];
        data[0] =
            @as(u8, 0) << 7 | // Reserved
            @as(u8, @backingInt(self.colorspace)) << 5 |
            @as(u8, @intFromBool(self.active_aspect != .none)) << 4 |
            @as(u8, @intFromBool(self.top_bar != 0 or self.bottom_bar != 0)) << 3 |
            @as(u8, @intFromBool(self.left_bar != 0 or self.right_bar != 0)) << 2 |
            @backingInt(self.scan_mode) << 0;
        data[1] =
            @as(u8, @backingInt(self.colorimetry)) << 6 |
            @as(u8, @backingInt(self.picture_aspect)) << 4 |
            @backingInt(self.active_aspect) << 0;
        data[2] =
            @as(u8, @intFromBool(self.itc)) << 7 |
            @as(u8, self.extended_colorimetry) << 4 |
            @as(u8, @backingInt(self.quantization_range)) << 2 |
            @backingInt(self.nups) << 0;
        data[3] =
            @as(u8, 0) << 7 | // Reserved
            @as(u8, self.video_code);
        data[4] =
            @as(u8, @backingInt(self.ycc_quantization_range)) << 6 |
            @as(u8, @backingInt(self.content_type)) << 4 |
            self.pixel_repeat << 0;
        std.mem.writeInt(u16, data[5..7], self.top_bar, .little);
        std.mem.writeInt(u16, data[7..9], self.bottom_bar, .little);
        std.mem.writeInt(u16, data[9..11], self.left_bar, .little);
        std.mem.writeInt(u16, data[11..13], self.right_bar, .little);

        // Checksum.
        buffer[3] = checksum(&buffer);

        return buffer;
    }
};

/// Source device information.
pub const SpdSdi = enum(u8) {
    /// Unknown.
    unknown = 0,
    /// Digital STB
    dstb = 1,
    /// DVD player
    dvdp = 2,
    /// D-VHS
    dvhs = 3,
    /// HDD videorecorder
    hddvr = 4,
    /// DVC
    dvc = 5,
    /// DSC
    dsc = 6,
    /// Video CD
    vcd = 7,
    /// Game
    game = 8,
    /// PC general
    pc = 9,
    /// Blu-Ray disc
    bd = 10,
    /// Super Audio CD
    sacd = 11,
    /// HD DVD
    hddvd = 12,
    /// Portable Media Player.
    pmp = 13,
};

/// SPD InfoFrame version 1.
pub const Spd = struct {
    /// Size of the InfoFrame including the header.
    pub const size = header_size + data_length;
    /// Version of the InfoFrame.
    const version = 1;
    /// Length of the data bytes.
    const data_length = 25;

    /// Vendor name. Zero-padded.
    vendor: [8]u8,
    /// Product name. Zero-padded.
    product: [16]u8,
    /// Source device information.
    sdi: SpdSdi,

    /// Create the InfoFrame.
    ///
    /// Names longer than the field are truncated.
    pub fn init(vendor: []const u8, product: []const u8, sdi: SpdSdi) Spd {
        var spd = Spd{
            .vendor = @splat(0),
            .product = @splat(0),
            .sdi = sdi,
        };
        @memcpy(spd.vendor[0..@min(vendor.len, spd.vendor.len)], vendor);
        @memcpy(spd.product[0..@min(product.len, spd.product.len)], product);

        return spd;
    }

    /// Pack the InfoFrame into the binary representation with the header and the checksum.
    pub fn pack(self: Spd) [size]u8 {
        var buffer = std.mem.zeroes([size]u8);

        // Header bytes.
        buffer[0] = @backingInt(InfoFrameType.spd);
        buffer[1] = version;
        buffer[2] = data_length;

        // Data bytes.
        const data = buffer[header_size..];
        @memcpy(data[0..8], &self.vendor);
        @memcpy(data[8..24], &self.product);
        data[24] = @backingInt(self.sdi);

        // Checksum.
        buffer[3] = checksum(&buffer);

        return buffer;
    }
};

/// Calculate the checksum of the InfoFrame.
///
/// The checksum field must be zero in `buffer`.
fn checksum(buffer: []const u8) u8 {
    var sum: u8 = 0;
    for (buffer) |b| sum +%= b;
    return 0 -% sum;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
