test "unlinking an open file keeps its data accessible until closed" {
    const init = utest.getInit();
    var t = Test.init();

    const content = "hello-unlink";
    const wfile = try t.createFile();
    try wfile.writeStreamingAll(init.io, content);
    wfile.close(init.io);

    const dir = try std.Io.Dir.openDirAbsolute(
        init.io,
        Test.base_dir,
        .{},
    );
    defer dir.close(init.io);

    const rfile = try dir.openFile(
        init.io,
        Test.file_name,
        .{},
    );
    defer rfile.close(init.io);

    // Remove the directory entry of one file while another file is still open.
    t.deleteFile();

    // The already-open fd must still be able to read back the data.
    var buf: [content.len]u8 = undefined;
    var reader = rfile.reader(init.io, &.{});
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualSlices(u8, content, &buf);

    // Re-opening by name must now fail.
    try testing.expectError(error.FileNotFound, dir.openFile(
        init.io,
        Test.file_name,
        .{},
    ));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const Test = utest.fs.Test;
