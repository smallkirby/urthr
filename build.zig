const zon = @import("build.zig.zon");
const version = zon.version;

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    var iu = InstallUtil.init(b);

    // =============================================================
    // Options
    // =============================================================

    const board_type = b.option(
        board.BoardType,
        "board",
        "Target board type",
    ) orelse .rpi4b;

    const log_level = b.option(
        std.log.Level,
        "log_level",
        "Log level",
    ) orelse .info;

    const traces = b.option(
        []const u8,
        "trace",
        "Enable the trace outputs of the specified domains (comma-separated).",
    ) orelse "";
    const typed_traces = try generateTraceDomains(traces, b);

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

    const allow_init_exit = b.option(
        bool,
        "allow_init_exit",
        "Allow init process to exit.",
    ) orelse false;

    const qemu_dir = b.option(
        []const u8,
        "qemu",
        "Path to QEMU install directory",
    ) orelse "";

    const wait_qemu = b.option(
        bool,
        "wait_qemu",
        "QEMU waits for GDB connection.",
    ) orelse false;

    const enable_rtt = b.option(
        bool,
        "rtt",
        "Enable runtime tests in the kernel.",
    ) orelse false;

    const init_path = b.option(
        []const u8,
        "init",
        "Path to init binary to run on boot.",
    ) orelse "/boot/bin/init";

    const restart = b.option(
        bool,
        "restart",
        "Restart the CPU instead of halting on panic.",
    ) orelse false;

    const idle_watchdog = b.option(
        u64,
        "idle_watchdog",
        "Watchdog timeout in second for the idle thread. 0 to disable.",
    ) orelse 0;

    const qemu_log = b.option(
        []const u8,
        "qemu_log",
        "Enable specified QEMU verbose log outputs.",
    ) orelse "";

    const enable_graphic = b.option(
        bool,
        "graphic",
        "Enable graphical display window in QEMU.",
    ) orelse false;

    var sdin = b.option(
        []const u8,
        "sdin",
        "Path to SD card image file for QEMU.",
    ) orelse null;
    const sdcreate = b.option(
        bool,
        "sdcreate",
        "Create an SD card image file and use it for this run.",
    ) orelse false;
    if (sdcreate and sdin != null) {
        std.log.err("Cannot specify both --sdin and --sdcreate options.", .{});
        return error.InvalidOption;
    }

    const options = b.addOptions();
    options.addOption(std.log.Level, "log_level", log_level);
    options.addOption([]const []const u8, "trace", typed_traces);
    options.addOption(board.BoardType, "board", board_type);
    options.addOption(bool, "serial_boot", serial_boot);
    options.addOption(bool, "enable_rtt", enable_rtt);
    options.addOption([]const u8, "init", init_path);
    options.addOption(bool, "restart_on_panic", restart);
    options.addOption(u64, "idle_watchdog", idle_watchdog);
    options.addOption([]const u8, "version", version);
    options.addOption(bool, "allow_init_exit", allow_init_exit);

    const options_module = options.createModule();

    // =============================================================
    // Targets
    // =============================================================

    const bl_target = switch (board_type.arch()) {
        .aarch64 => b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .abi = .none,
            .os_tag = .freestanding,
            .ofmt = .elf,
            .cpu_features_add = std.Target.aarch64.featureSet(&[_]std.Target.aarch64.Feature{
                .strict_align,
                .el3,
            }),
            .cpu_features_sub = std.Target.aarch64.featureSet(&[_]std.Target.aarch64.Feature{
                .neon,
                .fp_armv8,
            }),
        }),
        .x86_64 => b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .uefi,
        }),
        else => unreachable,
    };
    const kernel_target = switch (board_type.arch()) {
        .aarch64 => b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .abi = .none,
            .os_tag = .freestanding,
            .ofmt = .elf,
            .cpu_features_add = std.Target.aarch64.featureSet(&[_]std.Target.aarch64.Feature{
                .strict_align,
                .el3,
            }),
            .cpu_features_sub = std.Target.aarch64.featureSet(&[_]std.Target.aarch64.Feature{
                .neon,
                .fp_armv8,
            }),
        }),
        .x86_64 => b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .abi = .none,
            .os_tag = .freestanding,
            .ofmt = .elf,
        }),
        else => unreachable,
    };
    const tools_target = b.standardTargetOptions(.{});

    // Set installation paths for the target and host.
    try iu.set(.target, .{
        .root = @tagName(board_type),
    });
    try iu.set(.host, .{
        .root = "host",
    });

    // =============================================================
    // Modules
    // =============================================================

    const boot_module = b.createModule(.{
        .root_source_file = b.path("boot.zig"),
    });
    const common_module = b.createModule(.{
        .root_source_file = b.path("urthr/common.zig"),
    });
    const arch_module = b.createModule(.{
        .root_source_file = b.path("urthr/arch.zig"),
    });
    const dd_module = b.createModule(.{
        .root_source_file = b.path("urthr/dd.zig"),
    });
    const board_module = b.createModule(.{
        .root_source_file = b.path("urthr/board.zig"),
    });
    const urthr_module = b.createModule(.{
        .root_source_file = b.path("urthr/urthr.zig"),
    });

    // Define dependency between modules.
    {
        common_module.addImport("common", common_module);
        common_module.addImport("options", options_module);
    }
    {
        arch_module.addImport("common", common_module);
        arch_module.addImport("options", options_module);
    }
    {
        dd_module.addImport("common", common_module);
        dd_module.addImport("arch", arch_module);
        dd_module.addImport("dd", dd_module);
        dd_module.addImport("urthr", urthr_module);
        dd_module.addImport("options", options_module);
    }
    {
        board_module.addImport("common", common_module);
        board_module.addImport("arch", arch_module);
        board_module.addImport("boot", boot_module);
        board_module.addImport("dd", dd_module);
        board_module.addImport("urthr", urthr_module);
        board_module.addImport("options", options_module);
    }
    {
        urthr_module.addImport("common", common_module);
        urthr_module.addImport("arch", arch_module);
        urthr_module.addImport("board", board_module);
        urthr_module.addImport("dd", dd_module);
        urthr_module.addImport("urthr", urthr_module);
        urthr_module.addImport("options", options_module);
    }

    // =============================================================
    // Tools
    // =============================================================

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
        exe.root_module.addImport("board", board_module);

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
        exe.root_module.addImport("urthr", urthr_module);
        exe.root_module.addImport("board", board_module);
        exe.root_module.addImport("common", common_module);

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
    iu.installArtifact(srboot, .host, .bin);

    const mkfont = blk: {
        const exe = b.addExecutable(.{
            .name = "mkfont",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/mkfont/main.zig"),
                .target = tools_target,
                .optimize = optimize,
            }),
        });

        break :blk exe;
    };
    iu.installArtifact(mkfont, .host, .bin);

    // =============================================================
    // Preprocess
    // =============================================================

    // Generate constants header.
    const const_header = blk: {
        const run = b.addRunArtifact(mkconst);
        const out = run.addOutputFileArg("constants.autogen.h");

        // Install generated header for debug.
        iu.installFile(out, "constants.autogen.h", .target, .include);

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
    // Font
    // =============================================================

    const font8x16 = blk: {
        const run = b.addRunArtifact(mkfont);
        run.addArg("--input");
        run.addFileArg(b.path("tools/mkfont/font_8x16.txt"));
        run.addArg("--output");
        break :blk run.addOutputFileArg("font8x16.zig");
    };

    {
        common_module.addAnonymousImport("font8x16", .{
            .root_source_file = font8x16,
        });
    }

    // =============================================================
    // Urthr Executable
    // =============================================================

    const urthr = blk: {
        const exe = b.addExecutable(.{
            .name = "urthr",
            .root_module = b.createModule(.{
                .root_source_file = b.path("urthr/main.zig"),
                .target = kernel_target,
                .optimize = optimize,
                .code_model = if (board_type.arch() == .x86_64) .large else .default,
                .pic = if (board_type.arch() == .x86_64) true else null,
            }),
            .linkage = .static,
            .use_llvm = true,
        });
        exe.entry = .{ .symbol_name = "_start" };
        exe.linker_script = urthr_ld;
        exe.root_module.addImport("common", common_module);
        exe.root_module.addImport("arch", arch_module);
        exe.root_module.addImport("board", board_module);
        exe.root_module.addImport("dd", dd_module);
        exe.root_module.addImport("urthr", urthr_module);
        exe.root_module.addImport("options", options_module);
        switch (board_type.arch()) {
            .aarch64 => {
                exe.root_module.addAssemblyFile(b.path("urthr/arch/aarch64/head.S"));
                exe.root_module.addAssemblyFile(b.path("urthr/arch/aarch64/isr.S"));
                exe.root_module.addAssemblyFile(b.path("urthr/arch/aarch64/switch.S"));
                exe.root_module.addAssemblyFile(b.path("urthr/arch/aarch64/thread.S"));
                exe.root_module.addAssemblyFile(b.path("urthr/arch/aarch64/smp.S"));
            },
            .x86_64 => {
                exe.root_module.addAssemblyFile(b.path("urthr/arch/x64/head.S"));
                exe.root_module.addAssemblyFile(b.path("urthr/arch/x64/switch.S"));
                exe.root_module.addAssemblyFile(b.path("urthr/arch/x64/thread.S"));
            },
            else => unreachable,
        }

        exe.step.dependOn(&pp_urthr.step);
        break :blk exe;
    };
    iu.installArtifact(urthr, .target, .bin);

    // Raw Urthr image.
    const urthr_bin = blk: {
        const objcopy = b.addObjCopy(urthr.getEmittedBin(), .{
            .format = .bin,
        });
        objcopy.step.dependOn(&urthr.step);
        break :blk iu.createInstallFile(
            objcopy.getOutput(),
            "urthr.img",
            .target,
            .bin,
        );
    };

    // =============================================================
    // Wyrd Executable
    // =============================================================

    const wyrd = blk: {
        const exe = b.addExecutable(.{
            .name = "wyrd",
            .root_module = b.createModule(.{
                .root_source_file = switch (board_type.arch()) {
                    .aarch64 => b.path("wyrd/aarch64/main.zig"),
                    .x86_64 => b.path("wyrd/x64/main.zig"),
                    else => unreachable,
                },
                .target = bl_target,
                .optimize = optimize,
            }),
            .linkage = .static,
            .use_llvm = true,
        });
        exe.linker_script = wyrd_ld;
        exe.root_module.addImport("boot", boot_module);
        exe.root_module.addImport("common", common_module);
        exe.root_module.addImport("arch", arch_module);
        exe.root_module.addImport("board", board_module);
        exe.root_module.addImport("dd", dd_module);
        exe.root_module.addImport("options", options_module);
        switch (board_type.arch()) {
            .aarch64 => {
                exe.entry = .{ .symbol_name = "_start" };
                exe.root_module.addAssemblyFile(b.path("urthr/arch/aarch64/head.S"));
                exe.root_module.addAssemblyFile(b.path("urthr/arch/aarch64/isr.S"));
            },
            .x86_64 => {},
            else => unreachable,
        }

        exe.step.dependOn(&pp_wyrd.step);
        break :blk exe;
    };
    iu.installArtifact(wyrd, .target, .bin);

    // Raw Wyrd image.
    const wyrd_bin = blk: {
        switch (board_type.arch()) {
            .aarch64 => {
                const objcopy = b.addObjCopy(wyrd.getEmittedBin(), .{
                    .format = .bin,
                });
                objcopy.step.dependOn(&wyrd.step);
                break :blk iu.createInstallFile(
                    objcopy.getOutput(),
                    "wyrd.img",
                    .target,
                    .bin,
                );
            },
            .x86_64 => {
                break :blk iu.createInstallFile(
                    wyrd.getEmittedBin(),
                    "efi/boot/BOOTX64.EFI",
                    .target,
                    .esp,
                );
            },
            else => unreachable,
        }
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
            break :blk iu.createInstallFile(
                wyrd_bin.source,
                booter_name,
                .target,
                .bin,
            );
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
            run.addArg("--encoding");
            run.addArg("zlib");
            run.addArg("--output");
            const out = run.addOutputFileArg(booter_name);

            break :blk iu.createInstallFile(
                out,
                booter_name,
                .target,
                .bin,
            );
        }
    };
    booter.step.dependOn(&wyrd_bin.step);
    booter.step.dependOn(&urthr_bin.step);
    b.getInstallStep().dependOn(&booter.step);

    // =============================================================
    // Remote
    // =============================================================

    // Remote: the second binary sent via serial by srboot.
    const remote = if (serial_boot or board_type == .q35) blk: {
        const remote_name = "remote";

        const run = b.addRunArtifact(mkimg);
        run.addArg("split");
        run.addArg("--urthr");
        run.addFileArg(urthr_bin.source);
        run.addArg("--urthr-elf");
        run.addFileArg(urthr.getEmittedBin());
        run.addArg("--encoding");
        run.addArg("zlib");
        run.addArg("--output");
        const out = run.addOutputFileArg(remote_name);

        const bin = iu.createInstallFile(
            out,
            remote_name,
            .target,
            .bin,
        );
        b.getInstallStep().dependOn(&bin.step);

        break :blk bin;
    } else null;

    // =============================================================
    // Applications / BootFS
    // =============================================================

    {
        const user_target = switch (board_type.arch()) {
            .aarch64 => b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .linux,
                .abi = .gnu,
                .ofmt = .elf,
                .cpu_features_sub = std.Target.aarch64.featureSet(&[_]std.Target.aarch64.Feature{
                    .neon,
                    .fp_armv8,
                }),
            }),
            .x86_64 => b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .linux,
                .abi = .gnu,
                .ofmt = .elf,
            }),
            else => unreachable,
        };

        // =============================================================
        // init

        const init = blk: {
            const exe = b.addExecutable(.{
                .name = "init",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("app/init/main.zig"),
                    .target = user_target,
                }),
                .linkage = .static,
                .use_llvm = true,
            });

            break :blk exe;
        };
        iu.installArtifact(init, .target, .bin);

        // =============================================================
        // utest

        const utest = blk: {
            const module = b.createModule(.{
                .root_source_file = b.path("app/utest/utest.zig"),
                .target = user_target,
            });

            const exe = b.addTest(.{
                .name = "utest",
                .root_module = module,
                .test_runner = .{
                    .path = b.path("app/utest/test_runner.zig"),
                    .mode = .simple,
                },
            });

            break :blk exe;
        };
        iu.installArtifact(utest, .target, .bin);

        // =============================================================
        // BootFS

        const bootfs = b.step("bootfs", "Create BootFS image");
        const apps = [_]*std.Build.Step.Compile{
            init,
            utest,
        };

        // Create bootfs.img from zig-out/bootfs directory.
        // This Run is executed if any of the apps are update,
        // while it does not care about other changes in the bootfs directory.
        const run = b.addSystemCommand(&.{
            "bash",
            "scripts/create_disk.bash",
        });
        run.addArg(b.fmt("zig-out/{s}/bootfs/boot", .{@tagName(board_type)}));
        const img = run.addOutputFileArg("bootfs.img");
        for (apps) |app| {
            const artifact = iu.createInstallArtifact(app, .target, .bootfs);
            run.step.dependOn(&artifact.step);
            run.addFileInput(artifact.emitted_bin.?);
        }

        bootfs.dependOn(&iu.createInstallFile(
            img,
            "bootfs.img",
            .target,
            .root,
        ).step);

        if (sdcreate) {
            b.getInstallStep().dependOn(bootfs);
            sdin = try std.fmt.allocPrint(b.allocator, "{s}/bootfs.img", .{iu.getInstallPath(.target, .root)});
        }
    }

    // =============================================================
    // Install
    // =============================================================

    {
        // Install booter as an appropriate name for the board.
        iu.installFile(
            booter.source,
            board_type.outname(),
            .target,
            .bin,
        );

        // Copy to the SD card if specified.
        if (sdcard) |path| {
            const run = b.addSystemCommand(&.{"cp"});
            run.addFileArg(booter.source);
            run.addArg(b.fmt("{s}/{s}", .{ path, board_type.outname() }));

            b.getInstallStep().dependOn(&run.step);
        }
    }

    // Create EFI system partition if target is Q35.
    if (board_type == .q35) {
        // Copy booter image to ESP.
        const cp_remote = iu.createInstallFile(
            remote.?.source,
            "efi/boot/remote",
            .target,
            .esp,
        );

        // Create ESP image.
        const run = b.addSystemCommand(&.{ "bash", "scripts/create_esp.bash" });
        run.addArg(iu.getInstallPath(.target, .esp));
        run.addArg(b.fmt("{s}/esp.img", .{iu.getInstallPath(.target, .root)}));
        run.step.dependOn(&cp_remote.step);
        b.getInstallStep().dependOn(&run.step);
    }

    // =============================================================
    // Run on QEMU
    // =============================================================

    {
        const qemu_bin = switch (board_type.arch()) {
            .aarch64 => b.fmt("{s}/qemu-system-aarch64", .{qemu_dir}),
            .x86_64 => b.fmt("{s}/qemu-system-x86_64", .{qemu_dir}),
            else => unreachable,
        };
        const drive = switch (board_type) {
            .q35 => b.fmt("{s}/esp.img", .{iu.getInstallPath(.target, .root)}),
            else => null,
        };
        const qemu = Qemu{
            .qemu = qemu_bin,
            .machine = board_type,
            .graphic = if (enable_graphic) .display else .none,
            .memory = "2G",
            .kernel = b.fmt(
                "{s}/{s}",
                .{ iu.getInstallPath(.target, .bin), booter.dest_rel_path },
            ),
            .serial = if (serial) |s| blk: {
                break :blk if (std.mem.eql(u8, s, "pts")) .pts else .stdio;
            } else .stdio,
            .sd = sdin,
            .drive = drive,
            .verbose_logs = qemu_log,
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

    var ut = UnitTests.new(b);

    try ut.addTestModule(
        "common_test",
        b.path("urthr/common.zig"),
        &.{},
        optimize,
    );
    try ut.addTestModule(
        "dd_test",
        b.path("urthr/dd.zig"),
        &.{
            .{ .name = "common", .module = common_module },
            .{ .name = "arch", .module = arch_module },
        },
        optimize,
    );
    try ut.addTestModule(
        "urthr_test",
        b.path("urthr/urthr.zig"),
        &.{
            .{ .name = "common", .module = common_module },
            .{ .name = "dd", .module = dd_module },
            .{ .name = "urthr", .module = null },
        },
        optimize,
    );

    // =============================================================
    // Docs
    // =============================================================

    const urthr_docs = b.addInstallDirectory(.{
        .source_dir = urthr.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/urthr",
    });
    const wyrd_docs = b.addInstallDirectory(.{
        .source_dir = wyrd.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/wyrd",
    });

    const docs = b.step("docs", "Generate documentation");
    docs.dependOn(&urthr_docs.step);
    docs.dependOn(&wyrd_docs.step);
}

const InstallUtil = struct {
    const Self = @This();

    /// Build instance.
    b: *std.Build,
    /// Installation target map.
    targets: std.AutoHashMap(Target, InstallPath),

    const Target = enum {
        /// Host tools.
        host,
        /// Target artifacts.
        target,
    };

    const Sub = enum {
        /// Root directory.
        root,
        /// Binary directory.
        bin,
        /// BootFS raw directory.
        bootfs,
        /// Include directory for auto-generated headers.
        include,
        /// EFI System Partition root.
        esp,
    };

    // Target specific installation information.
    const InstallPath = struct {
        root: []const u8,
    };

    pub fn init(b: *std.Build) Self {
        return .{
            .b = b,
            .targets = .init(b.allocator),
        };
    }

    pub fn set(self: *Self, target: Target, paths: InstallPath) !void {
        try self.targets.put(target, paths);
    }

    /// Create a step to install the artifact without appending it to the install step.
    pub fn createInstallArtifact(self: *Self, artifact: *std.Build.Step.Compile, target: Target, sub: Sub) *std.Build.Step.InstallArtifact {
        return self.b.addInstallArtifact(artifact, .{
            .dest_dir = .{ .override = .{ .custom = self.getPath(target, sub) } },
        });
    }

    /// Append the artifact to the install step.
    pub fn installArtifact(self: *Self, artifact: *std.Build.Step.Compile, target: Target, sub: Sub) void {
        self.b.getInstallStep().dependOn(&self.createInstallArtifact(artifact, target, sub).step);
    }

    /// Create a file to be installed without appending it to the install step.
    pub fn createInstallFile(self: *Self, artifact: std.Build.LazyPath, name: []const u8, target: Target, sub: Sub) *std.Build.Step.InstallFile {
        return self.b.addInstallFileWithDir(
            artifact,
            .{ .custom = self.getPath(target, sub) },
            name,
        );
    }

    /// Append the file to the install step.
    pub fn installFile(self: *Self, artifact: std.Build.LazyPath, name: []const u8, target: Target, sub: Sub) void {
        self.b.getInstallStep().dependOn(&self.createInstallFile(artifact, name, target, sub).step);
    }

    fn getPath(self: *Self, target: Target, sub: Sub) []const u8 {
        const map = self.targets.get(target) orelse @panic("Unrecognized target");
        return switch (sub) {
            .root => map.root,
            .bin => self.b.fmt("{s}/bin", .{map.root}),
            .bootfs => self.b.fmt("{s}/bootfs/boot/bin", .{map.root}),
            .include => self.b.fmt("{s}/include", .{map.root}),
            .esp => self.b.fmt("{s}/esp", .{map.root}),
        };
    }

    /// Get installation path for the given target.
    ///
    /// Example: `zig-out/rpi4b/bin`, but `zig-out` part is determined by user option.
    pub fn getInstallPath(self: *Self, target: Target, sub: Sub) []const u8 {
        return self.b.fmt("{s}/{s}", .{ self.b.install_path, self.getPath(target, sub) });
    }
};

/// Create a new preprocess "Run" and return its artifact.
fn preprocess(b: *std.Build, input: LazyPath, output: []const u8, deps: []const LazyPath) struct { LazyPath, *InstallFile } {
    const run = b.addSystemCommand(&.{"cpp"});
    run.addArg("-P");
    run.addArg(b.fmt("-I{s}/include", .{b.install_path}));
    for (deps) |dep| {
        run.addPrefixedDirectoryArg("-I", dep.dirname());
        run.addFileInput(dep);
    }
    run.addFileArg(input);

    const out = run.addPrefixedOutputFileArg("-o", output);
    const ld = b.addInstallFile(out, output);

    return .{ out, ld };
}

/// Generate list of domains to enable trace outputs.
fn generateTraceDomains(s: []const u8, b: *std.Build) ![][]const u8 {
    const count_max = std.mem.count(u8, s, ",") + 1;
    const domains = try b.allocator.alloc([]const u8, count_max);
    var iter = std.mem.splitAny(u8, s, ",");
    var count: usize = 0;
    while (iter.next()) |part| : (count += 1) {
        const p = std.mem.trim(u8, part, " ");
        domains[count] = try b.allocator.dupe(u8, p);
    }

    return domains[0..count];
}

const ImportPair = struct {
    name: []const u8,
    module: ?*std.Build.Module,
};

const UnitTests = struct {
    build: *std.Build,
    step: *std.Build.Step,

    pub fn new(b: *std.Build) UnitTests {
        return UnitTests{
            .build = b,
            .step = b.step("test", "Run unit tests"),
        };
    }

    pub fn addTestModule(
        self: *UnitTests,
        comptime name: []const u8,
        root: LazyPath,
        imports: []const ImportPair,
        optimize: std.builtin.OptimizeMode,
    ) !void {
        const unit_test = self.build.addTest(.{
            .name = name,
            .root_module = self.build.createModule(.{
                .root_source_file = root,
                .target = self.build.resolveTargetQuery(.{}),
                .optimize = optimize,
                .link_libc = true,
            }),
            .use_llvm = true,
        });
        for (imports) |import| {
            unit_test.root_module.addImport(
                import.name,
                import.module orelse unit_test.root_module,
            );
        }

        const run_unit_test = self.build.addRunArtifact(unit_test);
        self.step.dependOn(&run_unit_test.step);
    }
};

const Qemu = struct {
    /// QEMU path.
    qemu: []const u8,
    /// Machine type.
    machine: board.BoardType,
    /// Graphics mode.
    graphic: enum { none, display },
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
    /// Path to SD card image file.
    sd: ?[]const u8,
    /// Path to drive image file.
    drive: ?[]const u8,
    /// QEMU verbose log outputs.
    verbose_logs: []const u8,
    /// Wait for GDB connection on startup.
    wait_gdb: bool,

    pub fn command(self: Qemu, allocator: std.mem.Allocator) ![]const []const u8 {
        const machine_name = switch (self.machine) {
            .rpi4b => "raspi4b",
            .rpi5 => "raspi5",
            .virt => "virt-9.0,gic-version=3,secure=on,virtualization=on",
            .q35 => "q35",
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
        switch (self.machine) {
            .virt => try args.appendSlice(allocator, &.{
                "-cpu",
                "cortex-a76",
                "-smp",
                "4",
            }),
            .q35 => try args.appendSlice(allocator, &.{
                "-bios",
                "/usr/share/ovmf/OVMF.fd", // TODO
                "-drive",
                try std.fmt.allocPrint(allocator, "file={s},format=raw,if=virtio,media=disk", .{self.drive.?}),
            }),
            else => {},
        }
        try args.appendSlice(allocator, &.{
            "-m",
            self.memory,
        });
        if (self.machine != .q35) {
            try args.appendSlice(allocator, &.{
                "-kernel",
                self.kernel,
            });
        }
        switch (self.graphic) {
            .none => try args.appendSlice(allocator, &.{"-nographic"}),
            .display => try args.appendSlice(allocator, &.{ "-display", "gtk" }),
        }
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
        if (self.sd) |sd_path| {
            switch (self.machine) {
                .rpi4b, .rpi5 => try args.appendSlice(allocator, &.{
                    "-sd",
                    sd_path,
                }),
                .virt => try args.appendSlice(allocator, &.{
                    "-device",
                    "virtio-blk-device,drive=disk",
                    "-drive",
                    try std.fmt.allocPrint(allocator, "file={s},format=raw,if=none,media=disk,id=disk", .{sd_path}),
                }),
                .q35 => unreachable,
            }
        }
        switch (self.machine) {
            .rpi4b, .virt => try args.appendSlice(allocator, &.{
                "-semihosting",
            }),
            else => {},
        }
        if (self.wait_gdb) {
            try args.appendSlice(allocator, &.{
                "-S",
            });
        }

        // Default peripherals
        switch (self.machine) {
            .virt => try args.appendSlice(allocator, &.{
                "-object",
                "rng-random,id=rng0,filename=/dev/urandom",
                "-device",
                "virtio-rng-device,rng=rng0",
                "-device",
                "VGA",
                "-device",
                "nec-usb-xhci,id=xhci",
                "-device",
                "usb-kbd",
            }),
            else => {},
        }

        // Enable verbose logs.
        var logiter = std.mem.splitAny(u8, self.verbose_logs, ",");
        while (logiter.next()) |log| {
            if (log.len == 0) continue;

            if (std.mem.eql(u8, log, "sd")) {
                try args.appendSlice(allocator, &.{
                    "-trace",
                    "sdhci_*",
                    "-trace",
                    "sdcard_*",
                });
                continue;
            }
            if (std.mem.eql(u8, log, "usb")) {
                try args.appendSlice(allocator, &.{
                    "-trace",
                    "xhci_*",
                    "-trace",
                    "usb_*",
                });
                continue;
            }
            if (std.mem.eql(u8, log, "gic")) {
                try args.appendSlice(allocator, &.{
                    "-trace",
                    "gic*",
                });
                continue;
            }

            @panic("Unsupported QEMU log option.");
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
