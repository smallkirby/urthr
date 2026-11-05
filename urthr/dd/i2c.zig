pub const Error = error{
    /// The target did not acknowledge.
    Nak,
    /// The controller did not complete the transfer in time.
    Timeout,
    /// The message is not supported by the controller.
    Unsupported,
};

/// Single I2C message.
///
/// Consecutive messages are joined by a repeated start.
pub const Msg = struct {
    /// 7-bit target address.
    addr: u7,
    /// Transfer direction.
    dir: Direction,
    /// Data to be sent or received.
    buf: []u8,

    pub const Direction = enum {
        write,
        read,
    };
};

/// I2C bus controller.
pub const Adapter = struct {
    /// Opaque pointer to the controller context.
    ptr: *anyopaque,
    /// I2C controller vtable.
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Transfer messages in order.
        xfer: *const fn (ctx: *anyopaque, msgs: []const Msg) Error!void,
    };

    /// Transfer messages in order.
    pub fn xfer(self: Adapter, msgs: []const Msg) Error!void {
        return self.vtable.xfer(self.ptr, msgs);
    }
};

pub const BrcmStb = @import("i2c/BrcmStb.zig");
