//! IP protocol implementation.

pub const vtable = net.Protocol.Vtable{
    .input = inputImpl,
};

fn inputImpl(data: []const u8) net.Error!void {
    log.debug("IP packet:", .{});
    util.hexdump(data, data.len, log.debug);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.ip);
const common = @import("common");
const util = common.util;
const urd = @import("urthr");
const net = urd.net;
