//! fsync: Write back the file to the underlying storage.
//!

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var argiter = init.minimal.args.iterate();
    defer argiter.deinit();
    _ = argiter.next(); // skip program name

    const path = argiter.next() orelse {
        log.err("Usage: fsync <path>", .{});
        std.process.exit(1);
    };

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    try file.sync(io);
}

const std = @import("std");
const log = std.log.scoped(.fsync);
