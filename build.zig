pub fn build(b: *std.Build) !void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .abi = .none,
        .os_tag = .freestanding,
        .ofmt = .elf,
    });
    const optimize = b.standardOptimizeOption(.{});

    // =============================================================
    // Options
    // =============================================================

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

    // =============================================================
    // Modules
    // =============================================================

    const urthr_module = blk: {
        const module = b.createModule(.{
            .root_source_file = b.path("src/urthr.zig"),
        });
        module.addImport("urthr", module);
        module.addOptions("options", options);

        break :blk module;
    };

    // =============================================================
    // Urthr Executable
    // =============================================================

    const urthr = blk: {
        const exe = b.addExecutable(.{
            .name = "urthr",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .linkage = .static,
            .use_llvm = true,
        });
        exe.entry = .{ .symbol_name = "_start" };
        exe.linker_script = b.path("src/arch/aarch64/linker.ld");
        exe.addAssemblyFile(b.path("src/arch/aarch64/entry.S"));
        exe.root_module.addImport("urthr", urthr_module);
        exe.root_module.addOptions("options", options);

        break :blk exe;
    };

    const kernel8 = blk: {
        const objcopy = b.addObjCopy(urthr.getEmittedBin(), .{
            .format = .bin,
        });

        objcopy.step.dependOn(&urthr.step);

        break :blk b.addInstallBinFile(objcopy.getOutput(), "kernel8.img");
    };

    // =============================================================
    // Urthr Executable
    // =============================================================

    const qemu_bin = b.fmt("{s}/bin/qemu-system-aarch64", .{qemu_dir});
    {
        var qemu_args = std.array_list.Aligned(
            []const u8,
            null,
        ).empty;
        defer qemu_args.deinit(b.allocator);
        try qemu_args.appendSlice(b.allocator, &.{
            qemu_bin,
            "-M",
            "raspi4b",
            "-kernel",
            b.fmt("{s}/bin/{s}", .{ b.install_path, kernel8.dest_rel_path }),
            "-nographic",
            "-serial",
            "mon:stdio",
            "-no-reboot",
            "-s",
            "-d",
            "guest_errors",
        });

        if (wait_qemu) {
            try qemu_args.append(b.allocator, "-S");
        }

        const qemu_cmd = b.addSystemCommand(qemu_args.items);
        qemu_cmd.step.dependOn(b.getInstallStep());

        const run_qemu = b.step("run", "Run Urthr on QEMU");
        run_qemu.dependOn(&qemu_cmd.step);
    }

    // =============================================================
    // Install
    // =============================================================

    b.installArtifact(urthr);
    b.getInstallStep().dependOn(&kernel8.step);

    // =============================================================
    // Unit Tests
    // =============================================================

    {
        const unit_test = b.addTest(.{
            .name = "urthr_test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/urthr.zig"),
                .target = b.resolveTargetQuery(.{}),
                .optimize = optimize,
                .link_libc = true,
            }),
            .use_llvm = true,
        });
        unit_test.root_module.addImport("urthr", unit_test.root_module);
        unit_test.root_module.addOptions("options", options);

        const run_unit_test = b.addRunArtifact(unit_test);
        const unit_test_step = b.step("test", "Run unit tests");
        unit_test_step.dependOn(&run_unit_test.step);
    }
}

fn home() []const u8 {
    return std.process.getEnvVarOwned(std.heap.page_allocator, "HOME") catch "..";
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
