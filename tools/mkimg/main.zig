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
    /// How the Urthr kernel binary is encoded.
    encoding,
};

/// Options map.
const optmap = std.StaticStringMap(Options).initComptime(&.{
    .{ "--wyrd", .wyrd },
    .{ "--urthr", .urthr },
    .{ "--urthr-elf", .urthr_elf },
    .{ "--output", .output },
    .{ "--encoding", .encoding },
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
        \\  --encoding <type>    How the Urthr kernel binary is encoded (none, zlib)
    ,
        .{},
    );

    std.process.exit(1);
}

/// Command line options.
const Args = struct {
    wyrd: ?std.Io.File = null,
    urthr: ?std.Io.File = null,
    urthr_elf: ?std.Io.File = null,
    output: ?std.Io.File = null,
    encoding: UrthrHeader.Encoding = .none,
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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = Args{};
    var argiter = init.minimal.args.iterate();
    defer argiter.deinit();
    _ = argiter.next(); // skip program name

    const mode = if (argiter.next()) |arg|
        Mode.from(arg) orelse usage(log.err)
    else {
        usage(log.err);
    };

    // Open CWD.
    var cwd_buf: [128]u8 = undefined;
    const cwd_path = cwd_buf[0..try std.process.currentPath(init.io, &cwd_buf)];
    const cwd = try std.Io.Dir.openDirAbsolute(init.io, cwd_path, .{});
    defer cwd.close(init.io);

    // Parse arguments.
    while (argiter.next()) |arg| {
        switch (optmap.get(arg) orelse usage(log.err)) {
            .wyrd => {
                const path = argiter.next() orelse usage(log.err);
                args.wyrd = try cwd.openFile(io, path, .{});
            },
            .urthr => {
                const path = argiter.next() orelse usage(log.err);
                args.urthr = try cwd.openFile(io, path, .{});
            },
            .urthr_elf => {
                const path = argiter.next() orelse usage(log.err);
                args.urthr_elf = try cwd.openFile(io, path, .{});
            },
            .output => {
                const path = argiter.next() orelse usage(log.err);
                args.output = try cwd.createFile(io, path, .{});
            },
            .encoding => {
                const s = argiter.next() orelse usage(log.err);
                args.encoding = if (std.mem.eql(u8, s, "none"))
                    .none
                else if (std.mem.eql(u8, s, "zlib"))
                    .zlib
                else
                    usage(log.err);
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
        .io = io,
        .encoding = args.encoding,
    };
    defer mkimg.deinit();

    // Compose the image file.
    try mkimg.compose();
}

const MkImage = struct {
    const Self = @This();

    mode: Mode,
    wyrd: ?std.Io.File = null,
    urthr: std.Io.File,
    urthr_elf: std.Io.File,
    output: std.Io.File,
    encoding: UrthrHeader.Encoding,
    io: std.Io,

    /// Create the image file.
    pub fn compose(self: *Self) !void {
        var wbuf: [4096]u8 = undefined;
        var writer = self.output.writer(self.io, &wbuf);

        // Size check
        if (self.mode == .single) {
            var total: usize = 0;

            total += (try self.wyrd.?.stat(self.io)).size;
            total += @sizeOf(UrthrHeader);
            total += (try self.urthr.stat(self.io)).size;

            if (@hasDecl(memmap, "loader_reserved")) {
                if (memmap.loader_reserved.start - memmap.loader < total) {
                    return error.ImageTooLarge;
                }
            }
        }

        // Write Wyrd binary.
        switch (self.mode) {
            .single => _ = try self.copy(&self.wyrd.?, &writer.interface),
            else => {},
        }

        // Write Urthr binary first.
        const header_start = writer.logicalPos();
        const urthr_start = header_start + @sizeOf(UrthrHeader);
        try writer.seekTo(urthr_start);
        try self.writeUrthr(&self.urthr, &writer.interface);
        const urthr_size = writer.logicalPos() - urthr_start;

        // Write Urthr header.
        try writer.seekTo(header_start);
        try self.writeHeader(&writer.interface, urthr_size);
    }

    /// Deinitialize to release resources.
    pub fn deinit(self: *Self) void {
        if (self.wyrd) |w| {
            w.close(self.io);
        }
        self.urthr.close(self.io);
        self.urthr_elf.close(self.io);
        self.output.close(self.io);
    }

    /// Write Urthr header to the given writer.
    fn writeHeader(self: *Self, w: *std.Io.Writer, encoded_size: usize) !void {
        const info = try self.parseUrthr();

        // Construct header.
        var urthr_reader = self.urthr.reader(self.io, &.{});
        const header = UrthrHeader{
            .size = (try self.urthr.stat(self.io)).size,
            .encoded_size = encoded_size,
            .mem_size = info.mem_size,
            .load_at = info.load_addr,
            .checksum = try UrthrHeader.calcChecksum(&urthr_reader.interface),
            .entry = info.entry,
            .encoding = self.encoding,
        };

        // Write header.
        _ = try w.writeStruct(header, .little);

        try w.flush();
    }

    /// Copy from the given file to the given writer.
    ///
    /// Returns the number of bytes copied.
    fn copy(self: *Self, r: *std.Io.File, w: *std.Io.Writer) !usize {
        var rbuf: [4096]u8 = undefined;

        var reader = r.reader(self.io, &rbuf);
        const size = try reader.interface.streamRemaining(w);

        try w.flush();

        return size;
    }

    /// Parse Urthr ELF file and get kernel info.
    fn parseUrthr(self: *Self) !UrthrInfo {
        var rbuf: [4096]u8 = undefined;

        var urthr_elf_reader = self.urthr_elf.reader(self.io, &rbuf);
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

    /// Write Urthr binary using the given encoding.
    ///
    /// Returns the encoded size.
    fn writeUrthr(self: *Self, r: *std.Io.File, w: *std.Io.Writer) !void {
        switch (self.encoding) {
            .none => {
                _ = try self.copy(r, w);
            },
            .zlib => {
                var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
                var reader = r.reader(self.io, &.{});

                var flate = try std.compress.flate.Compress.init(
                    w,
                    &flate_buf,
                    .zlib,
                    .default,
                );
                _ = try reader.interface.streamRemaining(&flate.writer);
                try flate.finish();
                try w.flush();
            },
        }
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
const board = @import("board").impl;
const memmap = board.memmap;
const UrthrHeader = boot.UrthrHeader;
