//! mkimg: Make a kernel image file.
//!
//! mkimg composes a Urthr kernel image file by combining Wyrd binary,
//!
//! There're two mode to compose the image:
//!
//! ## Single
//!
//! In this mode, Wyrd binary, Urthr header, and Urthr binary are combined into a single binary.
//!
//! +-----------+
//! |   Wyrd    |
//! +-----------+
//! |  Header   |
//! +-----------+
//! |   Urthr   |
//! +-----------+
//!
//! ## Split
//!
//! In this mode, only Urthr header and Urthr binary are combined into a single binary.
//!
//! +-----------+
//! |  Header   |
//! +-----------+
//! |   Urthr   |
//! +-----------+
//!

const Options = enum {
    /// Path to Wyrd binary.
    wyrd,
    /// Path to Urthr binary.
    urthr,
    /// Path to Urthr ELF file.
    urthr_elf,
    /// Path to output image file.
    output,
};

/// Options map.
const optmap = std.StaticStringMap(Options).initComptime(&.{
    .{ "--wyrd", .wyrd },
    .{ "--urthr", .urthr },
    .{ "--urthr-elf", .urthr_elf },
    .{ "--output", .output },
});

/// Print a usage and exit.
fn usage(logger: anytype) noreturn {
    logger("Usage: mkimg (single|split) <args...>", .{});
    logger(
        \\Options:
        \\  --wyrd <path>        Path to Wyrd binary (required for 'single' mode)
        \\  --urthr <path>       Path to Urthr binary (required)
        \\  --urthr-elf <path>   Path to Urthr ELF file (required)
        \\  --output <path>      Path to output image file (required)
    ,
        .{},
    );

    std.process.exit(1);
}

/// Command line options.
const Args = struct {
    wyrd: ?fs.File = null,
    urthr: ?fs.File = null,
    urthr_elf: ?fs.File = null,
    output: ?fs.File = null,
};

/// Composing mode.
const Mode = enum {
    /// Wyrd + Header + Urthr
    single,
    /// Header + Urthr
    split,

    pub fn from(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "single")) {
            return .single;
        } else if (std.mem.eql(u8, s, "split")) {
            return .split;
        } else {
            return null;
        }
    }
};

pub fn main() !void {
    var args = Args{};
    var argiter = std.process.args();
    _ = argiter.next(); // skip program name

    const mode = if (argiter.next()) |arg|
        Mode.from(arg) orelse usage(log.err)
    else {
        usage(log.err);
    };

    // Parse arguments.
    while (argiter.next()) |arg| {
        switch (optmap.get(arg) orelse usage(log.err)) {
            .wyrd => {
                const path = argiter.next() orelse usage(log.err);
                args.wyrd = try fs.cwd().openFile(path, .{});
            },
            .urthr => {
                const path = argiter.next() orelse usage(log.err);
                args.urthr = try fs.cwd().openFile(path, .{});
            },
            .urthr_elf => {
                const path = argiter.next() orelse usage(log.err);
                args.urthr_elf = try fs.cwd().openFile(path, .{});
            },
            .output => {
                const path = argiter.next() orelse usage(log.err);
                args.output = try fs.cwd().createFile(path, .{});
            },
        }
    }

    // Instantiate MkImage instance based on the mode.
    var mkimg = MkImage{
        .mode = mode,
        .wyrd = args.wyrd,
        .urthr = args.urthr orelse usage(log.err),
        .urthr_elf = args.urthr_elf orelse usage(log.err),
        .output = args.output orelse usage(log.err),
    };
    defer mkimg.deinit();

    // Compose the image file.
    try mkimg.compose();
}

const MkImage = struct {
    const Self = @This();

    mode: Mode,
    wyrd: ?fs.File = null,
    urthr: fs.File,
    urthr_elf: fs.File,
    output: fs.File,

    /// Create the image file.
    pub fn compose(self: *Self) !void {
        var wbuf: [4096]u8 = undefined;
        var writer = self.output.writer(&wbuf);

        // Write Wyrd binary.
        switch (self.mode) {
            .single => try copy(&self.wyrd.?, &writer.interface),
            else => {},
        }

        // Write Urthr header.
        try self.writeHeader(&writer.interface);

        // Write Urthr binary.
        try copy(&self.urthr, &writer.interface);
    }

    /// Deinitialize to release resources.
    pub fn deinit(self: *Self) void {
        if (self.wyrd) |w| {
            w.close();
        }
        self.urthr.close();
        self.urthr_elf.close();
        self.output.close();
    }

    /// Write Urthr header to the given writer.
    fn writeHeader(self: *Self, w: *std.Io.Writer) !void {
        const urthr_size = (try self.urthr.stat()).size;
        const info = try self.parseUrthr();

        // Construct header.
        var urthr_reader = self.urthr.reader(&.{});
        const header = UrthrHeader{
            .size = urthr_size,
            .encoded_size = self.getEncodedSize(urthr_size),
            .mem_size = info.mem_size,
            .load_at = info.load_addr,
            .checksum = try UrthrHeader.calcChecksum(&urthr_reader.interface),
            .entry = info.entry,
            .encoding = .none,
        };

        // Write header.
        _ = try w.writeStruct(header, .little);

        try w.flush();
    }

    /// Copy from the given file to the given writer.
    fn copy(r: *fs.File, w: *std.Io.Writer) !void {
        var rbuf: [4096]u8 = undefined;

        var reader = r.reader(&rbuf);
        _ = try reader.interface.streamRemaining(w);

        try w.flush();
    }

    /// Parse Urthr ELF file and get kernel info.
    fn parseUrthr(self: *Self) !UrthrInfo {
        var rbuf: [4096]u8 = undefined;

        var urthr_elf_reader = self.urthr_elf.reader(&rbuf);
        const header = try std.elf.Header.read(&urthr_elf_reader.interface);

        var piter = header.iterateProgramHeaders(&urthr_elf_reader);
        var min_seg_addr: u64 = std.math.maxInt(u64);
        var max_seg_addr: u64 = 0;
        while (try piter.next()) |ph| {
            if (ph.p_type != std.elf.PT_LOAD) continue;

            if (ph.p_vaddr < min_seg_addr) {
                min_seg_addr = ph.p_vaddr;
            }

            if (ph.p_vaddr + ph.p_memsz > max_seg_addr) {
                max_seg_addr = ph.p_vaddr + ph.p_memsz;
            }
        }

        return .{
            .load_addr = min_seg_addr,
            .entry = header.entry,
            .mem_size = max_seg_addr - min_seg_addr,
        };
    }

    /// Get the encoded size.
    fn getEncodedSize(_: *Self, size: usize) usize {
        return size;
    }

    /// Urthr kernel information.
    const UrthrInfo = struct {
        /// Load address.
        load_addr: u64,
        /// Entry point.
        entry: u64,
        /// Memory size including NOBITS sections.
        mem_size: u64,
    };
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.mkimg);
const Base64Encoder = std.base64.Base64Encoder;
const fs = std.fs;
const os = std.os;
const boot = @import("boot");
const UrthrHeader = boot.UrthrHeader;
