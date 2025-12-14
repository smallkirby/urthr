pub fn build(b: *std.Build) !void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .abi = .none,
        .os_tag = .freestanding,
        .ofmt = .elf,
        .cpu_features_add = std.Target.aarch64.featureSet(&[_]std.Target.aarch64.Feature{
            .strict_align,
        }),
        .cpu_features_sub = std.Target.aarch64.featureSet(&[_]std.Target.aarch64.Feature{
            .neon,
            .fp_armv8,
        }),
    });
    const optimize = b.standardOptimizeOption(.{});

    // =============================================================
    // Options
    // =============================================================

    const s_board = b.option(
        []const u8,
        "board",
        "Target board type",
    ) orelse "rpi4b";
    const board_type = board.BoardType.from(s_board) orelse {
        std.log.err("Unsupported board type: {s}", .{s_board});
        return error.InvalidBoardType;
    };

    const s_log_level = b.option(
        []const u8,
        "log_level",
        "log_level",
    ) orelse "info";
    const log_level: std.log.Level = b: {
        const eql = std.mem.eql;
        break :b if (eql(u8, s_log_level, "debug"))
            .debug
        else if (eql(u8, s_log_level, "info"))
            .info
        else if (eql(u8, s_log_level, "warn"))
            .warn
        else if (eql(u8, s_log_level, "error"))
            .err
        else
            @panic("Invalid log level");
    };

    const serial_boot = b.option(
        bool,
        "serial_boot",
        "Wyrd waits for serial input to receive kernel image.",
    ) orelse false;

    const serial = b.option(
        []const u8,
        "serial",
        "Path to serial interface device.",
    ) orelse null;

    const sdcard = b.option(
        []const u8,
        "sdcard",
        "Path to SD card to install the kernel image.",
    ) orelse null;

    const qemu_dir = b.option(
        []const u8,
        "qemu",
        "Path to QEMU install directory",
    ) orelse b.fmt("{s}/qemu-aarch64", .{home()});

    const wait_qemu = b.option(
        bool,
        "wait_qemu",
        "QEMU waits for GDB connection.",
    ) orelse false;

    const options = b.addOptions();
    options.addOption(std.log.Level, "log_level", log_level);
    options.addOption(board.BoardType, "board", board_type);
    options.addOption(bool, "serial_boot", serial_boot);

    // =============================================================
    // Modules
    // =============================================================

    const boot_module = blk: {
        const module = b.createModule(.{
            .root_source_file = b.path("boot.zig"),
        });

        break :blk module;
    };

    const common_module = blk: {
        const module = b.createModule(.{
            .root_source_file = b.path("urthr/common.zig"),
        });
        module.addImport("common", module);
        module.addOptions("options", options);

        break :blk module;
    };

    const arch_module = blk: {
        const module = b.createModule(.{
            .root_source_file = b.path("urthr/arch.zig"),
        });
        module.addImport("common", common_module);
        module.addOptions("options", options);

        break :blk module;
    };

    const dd_module = blk: {
        const module = b.createModule(.{
            .root_source_file = b.path("urthr/dd.zig"),
        });
        module.addImport("common", common_module);
        module.addImport("arch", arch_module);

        break :blk module;
    };

    const board_module = blk: {
        const module = b.createModule(.{
            .root_source_file = b.path("urthr/board.zig"),
        });
        module.addImport("common", common_module);
        module.addImport("arch", arch_module);
        module.addImport("dd", dd_module);

        break :blk module;
    };

    const urthr_module = blk: {
        const module = b.createModule(.{
            .root_source_file = b.path("urthr/urthr.zig"),
        });
        module.addImport("common", common_module);
        module.addImport("arch", arch_module);
        module.addImport("board", board_module);
        module.addImport("dd", dd_module);
        module.addImport("urthr", module);

        break :blk module;
    };

    // =============================================================
    // Tools
    // =============================================================

    const tools_target = b.standardTargetOptions(.{});

    const vmemmmap_module = blk: {
        const module = b.createModule(.{
            .root_source_file = b.path("urthr/kernel/mem/vmemmap.zig"),
        });
        module.addImport("common", common_module);

        break :blk module;
    };

    const mkimg = blk: {
        const exe = b.addExecutable(.{
            .name = "mkimg",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/mkimg/main.zig"),
                .target = tools_target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("boot", boot_module);

        break :blk exe;
    };

    const mkconst = blk: {
        const exe = b.addExecutable(.{
            .name = "mkconst",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/mkconst/main.zig"),
                .target = tools_target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("board", board_module);
        exe.root_module.addImport("common", common_module);
        exe.root_module.addImport("vmemmap", vmemmmap_module);

        break :blk exe;
    };

    const srboot = blk: {
        const exe = b.addExecutable(.{
            .name = "srboot",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/srboot/main.zig"),
                .target = tools_target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("boot", boot_module);
        exe.root_module.addImport("common", common_module);

        break :blk exe;
    };
    b.installArtifact(srboot);

    // =============================================================
    // Preprocess
    // =============================================================

    // Generate constants header.
    const const_header = blk: {
        const run = b.addRunArtifact(mkconst);
        const out = run.addOutputFileArg("constants.autogen.h");

        // Install generated header for debug.
        b.getInstallStep().dependOn(
            &b.addInstallHeaderFile(out, "constants.autogen.h").step,
        );

        break :blk out;
    };

    // Preprocess linker scripts.
    const urthr_ld, const pp_urthr = preprocess(
        b,
        b.path("urthr/urthr.lds.ld"),
        "urthr.ld",
        &.{const_header},
    );
    const wyrd_ld, const pp_wyrd = preprocess(
        b,
        b.path("wyrd/wyrd.lds.ld"),
        "wyrd.ld",
        &.{const_header},
    );

    // =============================================================
    // Urthr Executable
    // =============================================================

    const urthr = blk: {
        const exe = b.addExecutable(.{
            .name = "urthr",
            .root_module = b.createModule(.{
                .root_source_file = b.path("urthr/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .linkage = .static,
            .use_llvm = true,
        });
        exe.entry = .{ .symbol_name = "_start" };
        exe.linker_script = urthr_ld;
        exe.addAssemblyFile(b.path("urthr/arch/aarch64/head.S"));
        exe.addAssemblyFile(b.path("urthr/arch/aarch64/isr.S"));
        exe.root_module.addImport("common", common_module);
        exe.root_module.addImport("arch", arch_module);
        exe.root_module.addImport("board", board_module);
        exe.root_module.addImport("dd", dd_module);
        exe.root_module.addImport("urthr", urthr_module);
        exe.root_module.addOptions("options", options);

        exe.step.dependOn(&pp_urthr.step);

        break :blk exe;
    };
    b.installArtifact(urthr);

    const urthr_bin = blk: {
        const objcopy = b.addObjCopy(urthr.getEmittedBin(), .{
            .format = .bin,
        });
        objcopy.step.dependOn(&urthr.step);

        const bin = b.addInstallBinFile(objcopy.getOutput(), "urthr.img");

        break :blk bin;
    };

    // =============================================================
    // Wyrd Executable
    // =============================================================

    const wyrd = blk: {
        const exe = b.addExecutable(.{
            .name = "wyrd",
            .root_module = b.createModule(.{
                .root_source_file = b.path("wyrd/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .linkage = .static,
            .use_llvm = true,
        });
        exe.entry = .{ .symbol_name = "_start" };
        exe.linker_script = wyrd_ld;
        exe.addAssemblyFile(b.path("urthr/arch/aarch64/head.S"));
        exe.addAssemblyFile(b.path("urthr/arch/aarch64/isr.S"));
        exe.root_module.addImport("boot", boot_module);
        exe.root_module.addImport("common", common_module);
        exe.root_module.addImport("arch", arch_module);
        exe.root_module.addImport("board", board_module);
        exe.root_module.addImport("dd", dd_module);
        exe.root_module.addOptions("options", options);

        exe.step.dependOn(&pp_wyrd.step);

        break :blk exe;
    };
    b.installArtifact(wyrd);

    const wyrd_bin = blk: {
        const objcopy = b.addObjCopy(wyrd.getEmittedBin(), .{
            .format = .bin,
        });
        objcopy.step.dependOn(&wyrd.step);

        const bin = b.addInstallBinFile(objcopy.getOutput(), "wyrd.img");

        break :blk bin;
    };

    // =============================================================
    // Booter image
    // =============================================================

    // Booter: the first binary loaded by EL3 firmware.
    //
    // On serial boot : Wyrd only.
    // Otherwise      : Wyrd + Urthr kernel image.
    const booter = blk: {
        const booter_name = "booter";

        if (serial_boot) {
            // Wryd serial is the booter.
            break :blk b.addInstallBinFile(wyrd_bin.source, booter_name);
        } else {
            // Wyrd + Urthr image is the booter.
            const run = b.addRunArtifact(mkimg);
            run.addArg("single");
            run.addArg("--wyrd");
            run.addFileArg(wyrd_bin.source);
            run.addArg("--urthr");
            run.addFileArg(urthr_bin.source);
            run.addArg("--urthr-elf");
            run.addFileArg(urthr.getEmittedBin());
            run.addArg("--output");
            const out = run.addOutputFileArg(booter_name);

            break :blk b.addInstallBinFile(out, booter_name);
        }
    };
    booter.step.dependOn(&wyrd_bin.step);
    booter.step.dependOn(&urthr_bin.step);
    b.getInstallStep().dependOn(&booter.step);

    // =============================================================
    // Remote
    // =============================================================

    // Remote: the second binary sent via serial by srboot.
    if (serial_boot) {
        const remote_name = "remote";

        const run = b.addRunArtifact(mkimg);
        run.addArg("split");
        run.addArg("--urthr");
        run.addFileArg(urthr_bin.source);
        run.addArg("--urthr-elf");
        run.addFileArg(urthr.getEmittedBin());
        run.addArg("--output");
        const out = run.addOutputFileArg(remote_name);

        const bin = b.addInstallBinFile(out, remote_name);
        b.getInstallStep().dependOn(&bin.step);
    }

    // =============================================================
    // Install
    // =============================================================

    {
        // Install booter as an appropriate name for the board.
        b.getInstallStep().dependOn(
            &b.addInstallBinFile(booter.source, board_type.outname()).step,
        );

        // Copy to the SD card if specified.
        if (sdcard) |path| {
            const run = b.addSystemCommand(&.{"cp"});
            run.addFileArg(booter.source);
            run.addArg(b.fmt("{s}/{s}", .{ path, board_type.outname() }));

            b.getInstallStep().dependOn(&run.step);
        }
    }

    // =============================================================
    // Run on QEMU
    // =============================================================

    {
        const qemu_bin = b.fmt(
            "{s}/bin/qemu-system-aarch64",
            .{qemu_dir},
        );
        const qemu = Qemu{
            .qemu = qemu_bin,
            .machine = board_type,
            .graphic = .none,
            .memory = "2G",
            .kernel = b.fmt(
                "{s}/bin/{s}",
                .{ b.install_path, booter.dest_rel_path },
            ),
            .serial = if (serial) |s| blk: {
                break :blk if (std.mem.eql(u8, s, "pts")) .pts else .stdio;
            } else .stdio,
            .wait_gdb = wait_qemu,
        };

        const qemu_cmd = b.addSystemCommand(
            try qemu.command(b.allocator),
        );
        qemu_cmd.step.dependOn(b.getInstallStep());

        const run_qemu = b.step("run", "Run Urthr on QEMU");
        run_qemu.dependOn(&qemu_cmd.step);
        run_qemu.dependOn(b.getInstallStep());
    }

    // =============================================================
    // Unit Tests
    // =============================================================

    {
        const unit_test = b.addTest(.{
            .name = "urthr_test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("urthr/test.zig"),
                .target = b.resolveTargetQuery(.{}),
                .optimize = optimize,
                .link_libc = true,
            }),
            .use_llvm = true,
        });

        const run_unit_test = b.addRunArtifact(unit_test);
        const unit_test_step = b.step("test", "Run unit tests");
        unit_test_step.dependOn(&run_unit_test.step);
    }
}

/// Get home directory path.
fn home() []const u8 {
    return std.process.getEnvVarOwned(std.heap.page_allocator, "HOME") catch "..";
}

/// Create a new preprocess "Run" and return its artifact.
fn preprocess(b: *std.Build, input: LazyPath, output: []const u8, deps: []const LazyPath) struct { LazyPath, *InstallFile } {
    const run = b.addSystemCommand(&.{"cpp"});
    run.addArg("-P");
    run.addArg(b.fmt("-I{s}/include", .{b.install_path}));
    run.addFileArg(input);
    for (deps) |dep| {
        run.addFileInput(dep);
    }

    const out = run.addPrefixedOutputFileArg("-o", output);
    const ld = b.addInstallFile(out, output);

    return .{ out, ld };
}

const Qemu = struct {
    /// QEMU path.
    qemu: []const u8,
    /// Machine type.
    machine: board.BoardType,
    /// Graphics mode.
    graphic: enum { none },
    /// Memory size.
    memory: []const u8,
    /// Kernel path.
    kernel: []const u8,
    /// How to handle serial I/O.
    serial: enum {
        /// Redirect serial to stdio.
        stdio,
        /// Redirect serial both to stdio and to a PTY.
        pts,
    },
    /// Wait for GDB connection on startup.
    wait_gdb: bool,

    pub fn command(self: Qemu, allocator: std.mem.Allocator) ![]const []const u8 {
        const machine_name = switch (self.machine) {
            .rpi4b => "raspi4b",
            .rpi5 => "raspi5",
        };

        var args = std.array_list.Aligned([]const u8, null).empty;
        defer args.deinit(allocator);

        try args.appendSlice(allocator, &.{
            self.qemu,
        });
        try args.appendSlice(allocator, &.{
            "-M",
            machine_name,
        });
        try args.appendSlice(allocator, &.{
            "-m",
            self.memory,
        });
        try args.appendSlice(allocator, &.{
            "-kernel",
            self.kernel,
        });
        try args.appendSlice(allocator, &.{switch (self.graphic) {
            .none => "-nographic",
        }});
        try args.appendSlice(allocator, &.{
            "-no-reboot",
        });
        try args.appendSlice(allocator, &.{
            "-s",
            "-d",
            "guest_errors",
        });
        switch (self.serial) {
            .stdio => try args.appendSlice(allocator, &.{
                "-serial",
                "mon:stdio",
            }),
            .pts => try args.appendSlice(allocator, &.{
                "-chardev",
                "stdio,id=term",
                "-chardev",
                "pty,id=pty0",
                "-chardev",
                "hub,id=hub0,chardevs.0=pty0,chardevs.1=term,mux=on",
                "-serial",
                "chardev:hub0",
                "-monitor",
                "none",
                // NOTE: '257' is out of available ASCII range, meaning no escape char.
                //  This prevents QEMU from interpreting any input bytes as commands.
                "-echr",
                "257",
            }),
        }
        if (self.wait_gdb) {
            try args.appendSlice(allocator, &.{
                "-S",
            });
        }

        return args.toOwnedSlice(allocator);
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const board = @import("urthr/board.zig");
const LazyPath = std.Build.LazyPath;
const InstallFile = std.Build.Step.InstallFile;
