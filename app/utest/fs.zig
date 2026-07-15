comptime {
    _ = @import("fs/chmod.zig");
    _ = @import("fs/close.zig");
    _ = @import("fs/cwd.zig");
    _ = @import("fs/dup.zig");
    _ = @import("fs/fcntl.zig");
    _ = @import("fs/ioctl.zig");
    _ = @import("fs/lseek.zig");
    _ = @import("fs/open.zig");
    _ = @import("fs/pipe.zig");
    _ = @import("fs/ppoll.zig");
    _ = @import("fs/preadv.zig");
    _ = @import("fs/pwritev.zig");
    _ = @import("fs/read.zig");
    _ = @import("fs/readv.zig");
    _ = @import("fs/stat.zig");
    _ = @import("fs/unlink.zig");
    _ = @import("fs/write.zig");
    _ = @import("fs/writev.zig");
}

pub const Test = struct {
    const Self = @This();

    /// Base directory name.
    pub const base_dir = "/boot";
    /// Name of the test file.
    pub const file_name = "test.txt";

    pub fn init() Self {
        return .{};
    }

    pub fn createFile(_: *const Self) !std.Io.File {
        const ini = utest.getInit();

        const dir = try std.Io.Dir.openDirAbsolute(
            ini.io,
            base_dir,
            .{},
        );
        defer dir.close(ini.io);

        return try dir.createFile(ini.io, file_name, .{});
    }

    pub fn deleteFile(_: *const Self) void {
        const ini = utest.getInit();

        const dir = std.Io.Dir.openDirAbsolute(
            ini.io,
            base_dir,
            .{},
        ) catch |err| {
            std.log.err("Failed to open base directory: {t}", .{err});
            std.process.exit(1);
        };
        defer dir.close(ini.io);

        dir.deleteFile(ini.io, file_name) catch |err| {
            std.log.err("Failed to delete test file: {t}", .{err});
            std.process.exit(1);
        };
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest.zig");
