//! Command builder to launch QEMU.
//!

const Self = @This();

/// QEMU path.
qemu: []const u8,
/// Machine type.
machine: board.BoardType,
/// Graphics mode.
graphic: enum { none, display },
/// Memory size.
memory: []const u8,
/// Kernel path.
kernel: LazyPath,
/// How to handle serial I/O.
serial: enum {
    /// Redirect serial to stdio.
    stdio,
    /// Redirect serial both to stdio and to a PTY.
    pts,
},
/// Path to SD card image file.
sd: ?LazyPath,
/// Path to drive image file.
drive: ?LazyPath,
/// QEMU verbose log outputs.
verbose_logs: []const u8,
/// Wait for GDB connection on startup.
wait_gdb: bool,
/// GDB server port.
gdb_port: u32,
/// Command line arguments passed to the init process via semihosting.
append: ?[]const u8,
/// Enable KVM acceleration.
kvm: bool = false,
/// Attach an IOMMU and put devices behind it.
iommu: bool = false,

/// fw_cfg file name used to pass the init process' command line arguments.
pub const fwcfg_name = "opt/urthr/init_args";

/// Construct QEMU command-line arguments.
pub fn command(self: Self, allocator: Allocator) ![]const Arg {
    const cfg = self.config();

    var ab = ArgBuilder{ .allocator = allocator };
    defer ab.list.deinit(allocator);

    // Machine type.
    try ab.add(&.{ self.qemu, "-M", cfg.machine });
    // CPU.
    if (cfg.cpu) |cpu| {
        try ab.add(&.{ "-cpu", cpu });
    }
    // KVM acceleration.
    if (self.kvm) {
        try ab.add(&.{"-enable-kvm"});
    }
    // SMP.
    if (cfg.smp) |smp| {
        try ab.add(&.{"-smp"});
        try ab.addFmt("{d}", .{smp});
    }
    // Firmware.
    if (cfg.bios) |bios| {
        try ab.add(&.{ "-bios", bios });
    }
    // Memory.
    try ab.add(&.{ "-m", self.memory });
    // Boot media.
    switch (cfg.boot) {
        .drive => {
            try self.bootDrive(&ab);
        },
        .kernel => {
            try ab.add(&.{"-kernel"});
            try ab.addFile(self.kernel);
        },
    }
    // Graphic output.
    switch (self.graphic) {
        .none => try ab.add(&.{"-nographic"}),
        .display => try ab.add(&.{ "-display", "gtk" }),
    }
    // Serial output.
    switch (self.serial) {
        .stdio => try ab.add(&.{
            "-serial", "mon:stdio",
        }),
        .pts => try ab.add(&.{
            "-chardev", "stdio,id=term",
            "-chardev", "pty,id=pty0",
            "-chardev", "hub,id=hub0,chardevs.0=pty0,chardevs.1=term,mux=on",
            "-serial",  "chardev:hub0",
            "-monitor", "none",
            // NOTE: '257' is out of available ASCII range, meaning no escape char.
            //  This prevents QEMU from interpreting any input bytes as commands.
            "-echr",    "257",
        }),
    }
    // SD card.
    if (self.sd) |sd_path| {
        switch (cfg.sd) {
            .unsupported => unreachable,
            .slot => {
                try ab.add(&.{"-sd"});
                try ab.addFile(sd_path);
            },
            .virtio_blk => {
                try ab.device("virtio-blk-device", .{ .drive = "disk" });
                try ab.drive(.{ .format = "raw", .@"if" = "none", .media = "disk", .id = "disk", .file = sd_path });
            },
        }
    }
    // Semihosting.
    if (cfg.semihosting) {
        try ab.add(&.{"-semihosting"});
    }
    // Debug-exit device.
    if (cfg.debug_exit) {
        try ab.device("isa-debug-exit", .{ .iobase = "0xF4", .iosize = "0x04" });
    }
    // fw-cfg device.
    if (cfg.fw_cfg) {
        if (self.append) |append| try ab.fwcfg(fwcfg_name, append);
    }
    // Traces.
    try self.traces(&ab);
    // GDB.
    try ab.add(&.{"-gdb"});
    try ab.addFmt("tcp::{d}", .{self.gdb_port});
    if (self.wait_gdb) try ab.add(&.{"-S"});
    // Misc options.
    try ab.add(&.{ "-d", "guest_errors" });
    try ab.add(&.{"-no-reboot"});
    // Peripheral devices.
    try self.peripherals(&ab);

    return ab.list.toOwnedSlice(allocator);
}

/// QEMU trace events.
const log_traces = [_]struct { name: []const u8, events: []const []const u8 }{
    .{ .name = "sd", .events = &.{ "sdhci_*", "sdcard_*" } },
    .{ .name = "usb", .events = &.{ "xhci_*", "usb_*" } },
    .{ .name = "gic", .events = &.{"gic*"} },
};

/// Construct a board-specific QEMU configuration.
fn config(self: Self) Config {
    return switch (self.machine) {
        .rpi5 => .{
            .machine = "raspi5",
            .sd = .slot,
        },
        .rpi4b => .{
            .machine = "raspi4b",
            .sd = .slot,
            .semihosting = true,
        },
        .virt => .{
            .machine = "virt-9.0,gic-version=3,secure=on,virtualization=on",
            .cpu = "cortex-a76",
            .smp = 4,
            .sd = .virtio_blk,
            .semihosting = true,
            .fw_cfg = true,
        },
        .q35 => .{
            .machine = if (self.iommu)
                "q35,kernel-irqchip=split" // LAPIC=KVM, IOAPIC=QEMU
            else
                "q35",
            .cpu = if (self.kvm)
                "host,+fsgsbase,+smap,+smep,+rdrand,+avx,+sse4.2,+xsave,+xsaveopt"
            else
                "qemu64,+fsgsbase,+smap,+smep,+rdrand,+avx,+sse4.2,+xsave,+xsaveopt",
            .smp = 4,
            .bios = "/usr/share/ovmf/OVMF.fd", // TODO
            .boot = .drive,
            .debug_exit = true,
            .fw_cfg = true,
        },
        .rv64virt => .{
            .machine = "virt",
            .cpu = "rv64",
            .smp = 4,
            .sd = .virtio_blk,
            .fw_cfg = true,
        },
    };
}

/// Append a virtio device.
fn virtio(self: Self, ab: *ArgBuilder, driver: []const u8, props: anytype) !void {
    try ab.deviceWith(driver, props, .{
        .iommu_platform = if (self.iommu) true else null,
        .@"disable-legacy" = if (self.iommu) true else null,
    });
}

/// Attach the boot disk image.
fn bootDrive(self: Self, ab: *ArgBuilder) !void {
    const path = self.drive.?;
    if (self.iommu) {
        try self.virtio(ab, "virtio-blk-pci", .{ .drive = "disk0", .bootindex = 0 });
        try ab.drive(.{ .format = "raw", .@"if" = "none", .id = "disk0", .file = path });
    } else {
        try ab.drive(.{ .format = "raw", .@"if" = "virtio", .media = "disk", .file = path });
    }
}

/// Attach default peripherals.
fn peripherals(self: Self, ab: *ArgBuilder) !void {
    switch (self.machine) {
        .virt => {
            try ab.object("rng-random", .{ .id = "rng0", .filename = "/dev/urandom" });
            try ab.device("virtio-rng-device", .{ .rng = "rng0" });
            try ab.device("VGA", .{});
            try ab.device("nec-usb-xhci", .{ .id = "xhci" });
            try ab.device("usb-kbd", .{});
            try ab.device("virtio-gpu-pci", .{});
        },
        .q35 => {
            if (self.iommu) try ab.device("amd-iommu", .{ .@"dma-remap" = true, .intremap = true });
            try ab.device("nec-usb-xhci", .{ .id = "xhci" });
            try ab.device("usb-kbd", .{});
            try ab.netdev("user", .{ .id = "net0" });
            try self.virtio(ab, "virtio-net-pci", .{ .netdev = "net0" });
            try self.virtio(ab, "virtio-gpu-pci", .{});
        },
        .rv64virt => if (self.graphic == .display) {
            try ab.device("virtio-gpu-device", .{});
        },
        else => {},
    }
}

/// Enable verbose logs.
fn traces(self: Self, ab: *ArgBuilder) !void {
    var iter = std.mem.splitAny(u8, self.verbose_logs, ",");
    next: while (iter.next()) |log| {
        if (log.len == 0) continue;

        for (log_traces) |t| {
            if (!std.mem.eql(u8, log, t.name)) continue;
            for (t.events) |event| try ab.add(&.{ "-trace", event });
            continue :next;
        }

        @panic("Unsupported QEMU log option.");
    }
}

/// Board-specific differences of the QEMU invocation.
const Config = struct {
    /// Machine name.
    machine: []const u8,
    /// CPU model.
    cpu: ?[]const u8 = null,
    /// Number of CPUs.
    smp: ?u8 = null,
    /// Firmware image.
    bios: ?[]const u8 = null,
    /// How the guest is booted.
    boot: enum {
        /// Load the booter image by `-kernel`.
        kernel,
        /// Boot from the disk image.
        drive,
    } = .kernel,
    /// How the SD card image is attached.
    sd: enum {
        /// SD is not supported on this board.
        unsupported,
        /// SD slot of the board.
        slot,
        /// VirtIO block device.
        virtio_blk,
    } = .unsupported,
    /// Enable semihosting.
    semihosting: bool = false,
    /// Attach a device to exit QEMU from the guest.
    debug_exit: bool = false,
    /// Pass the init process' arguments via fw_cfg.
    fw_cfg: bool = false,
};

// =============================================================
// Internals

const Arg = union(enum) {
    /// Simple string.
    str: []const u8,
    /// File path.
    file: LazyPath,
    /// File path with a prefix.
    prefixed_file: struct { prefix: []const u8, path: LazyPath },
};
const Args = std.array_list.Aligned(Arg, null);

/// Builder of QEMU command line arguments.
const ArgBuilder = struct {
    allocator: Allocator,
    list: Args = .empty,

    /// Append plain strings.
    fn add(self: *ArgBuilder, strs: []const []const u8) !void {
        for (strs) |str| {
            try self.list.append(self.allocator, .{ .str = str });
        }
    }

    /// Append a formatted string.
    fn addFmt(self: *ArgBuilder, comptime fmt: []const u8, args: anytype) !void {
        try self.add(&.{try std.fmt.allocPrint(self.allocator, fmt, args)});
    }

    /// Append a file path.
    fn addFile(self: *ArgBuilder, path: LazyPath) !void {
        try self.list.append(self.allocator, .{ .file = path });
    }

    /// `-device <driver>,<props>`
    fn device(self: *ArgBuilder, driver: []const u8, props: anytype) !void {
        try self.option("-device", driver, .{props});
    }

    /// `-device <driver>,<props>,<extra>`
    fn deviceWith(self: *ArgBuilder, driver: []const u8, props: anytype, extra: anytype) !void {
        try self.option("-device", driver, .{ props, extra });
    }

    /// `-drive <props>`
    fn drive(self: *ArgBuilder, props: anytype) !void {
        try self.option("-drive", "", .{props});
    }

    /// `-object <kind>,<props>`
    fn object(self: *ArgBuilder, kind: []const u8, props: anytype) !void {
        try self.option("-object", kind, .{props});
    }

    /// `-netdev <kind>,<props>`
    fn netdev(self: *ArgBuilder, kind: []const u8, props: anytype) !void {
        try self.option("-netdev", kind, .{props});
    }

    /// `-fw_cfg name=<name>,string=<value>`
    fn fwcfg(self: *ArgBuilder, name: []const u8, value: []const u8) !void {
        try self.add(&.{"-fw_cfg"});
        try self.addFmt("name={s},string={s}", .{ name, value });
    }

    /// Append `<flag> <head>,<k>=<v>,...`.
    fn option(self: *ArgBuilder, flag: []const u8, head: []const u8, propsets: anytype) !void {
        const allocator = self.allocator;

        var buf = std.array_list.Aligned(u8, null).empty;
        try buf.appendSlice(allocator, head);

        var path: ?LazyPath = null;
        inline for (propsets) |props| {
            inline for (@typeInfo(@TypeOf(props)).@"struct".field_names) |name| try appendProp(
                &buf,
                &path,
                name,
                @field(props, name),
                allocator,
            );
        }

        try self.add(&.{flag});
        if (path) |p| {
            try self.list.append(allocator, .{ .prefixed_file = .{
                .prefix = buf.items,
                .path = p,
            } });
        } else {
            try self.add(&.{buf.items});
        }
    }

    /// Append a single property key=value to the buffer.
    ///
    /// The property is converted based on the type of `value` as follows:
    /// - bool      : `on` / `off`
    /// - integer   : decimal
    /// - string    : as is
    /// - optional  : unwrapped if not null
    /// - LazyPath  : file path, must be the last property
    fn appendProp(
        buf: *std.array_list.Aligned(u8, null),
        path: *?LazyPath,
        name: []const u8,
        value: anytype,
        allocator: Allocator,
    ) !void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            // nop
            .null => {
                return;
            },
            // Unwrap if not null
            .optional => {
                return if (value) |v| appendProp(buf, path, name, v, allocator);
            },
            // Process other types normally
            else => {},
        }
        // File path must be at last.
        std.debug.assert(path.* == null);

        if (buf.items.len != 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, name);
        try buf.append(allocator, '=');

        if (T == LazyPath) {
            path.* = value;
            return;
        }
        switch (@typeInfo(T)) {
            .bool => try buf.appendSlice(allocator, if (value) "on" else "off"),
            .int, .comptime_int => try buf.print(allocator, "{d}", .{value}),
            .pointer => try buf.appendSlice(allocator, value),
            else => @compileError("Unsupported QEMU property type: " ++ @typeName(T)),
        }
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const LazyPath = std.Build.LazyPath;
const board = @import("urthr/board.zig");
