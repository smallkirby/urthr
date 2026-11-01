//! BCM2712 ARM-to-VideoCore Mailbox.
//!
//! ref. https://github.com/raspberrypi/firmware/wiki/Mailboxes
//! ref. https://github.com/raspberrypi/firmware/wiki/Accessing-mailboxes

// =============================================================
// Module Definition
// =============================================================

var mbox = mmio.Module(.{ .size = u32 }, &.{
    // MB#0 is always for VC to ARM. Can't write to it.
    .{ 0x00, Mbox0Read },
    .{ 0x18, Mbox0Status },
    // MB#1 is always for ARM to VC. Can't read from it.
    .{ 0x20, Mbox1Write },
    .{ 0x38, Mbox1Status },
}){};

// =============================================================
// API
// =============================================================

/// Set the base address of the mailbox registers.
pub fn setBase(base: usize) void {
    mbox.setBase(base);
}

/// Send a property message to VideoCore and wait for the response.
pub fn call(channel: Channels, phys: u32) void {
    // Read the status register until the full flag is not set.
    while (mbox.read(Mbox1Status).full) {
        std.atomic.spinLoopHint();
    }

    // Write the data combined with the channel.
    mbox.write(Mbox1Write, .{
        .channel = channel,
        .data = @as(u28, @truncate(phys >> 4)),
    });

    // Wait for the response.
    while (true) {
        while (mbox.read(Mbox0Status).empty) {
            std.atomic.spinLoopHint();
        }

        if (mbox.read(Mbox0Read).channel == channel) {
            break;
        }
    }
}

// =============================================================
// Properties
// =============================================================

pub const props = struct {
    pub const Error = DmaAllocator.Error || error{
        /// VideoCore failed to process the request.
        DeviceError,
    };

    /// Tag IDs.
    pub const Tag = enum(u32) {
        /// End tag.
        end = 0x0000_0000,
        /// Get the clock state.
        get_clock_state = 0x0003_0001,
        /// Get the clock rate for the given clock.
        get_clock_rate = 0x0003_0002,
        /// Get the max supported clock rate for the given clock.
        get_max_clock_rate = 0x0003_0004,
        /// Get the minimum supported clock rate for the given clock.
        get_min_clock_rate = 0x0003_0007,
        /// Set the clock state.
        set_clock_state = 0x0003_8001,
        /// Set the clock rate.
        set_clock_rate = 0x0003_8002,
        /// Allocate buffer.
        alloc_buf = 0x0004_0001,
        /// Get pitch.
        get_pitch = 0x0004_0008,
        /// Set physical (display) width / height
        set_phys_wh = 0x0004_8003,
        /// Set virtual (buffer) width / height
        set_virt_wh = 0x0004_8004,
        /// Set depth.
        set_depth = 0x0004_8005,
        /// Set pixel order.
        set_pixel_order = 0x0004_8006,
        /// Set virtual offset.
        set_virt_off = 0x0004_8009,
    };

    /// Utility struct to build mailbox messages.
    pub const MessageBuilder = struct {
        /// Message buffer.
        buf: []u32,
        /// Current index in the message buffer.
        index: usize,

        pub fn init(buf: []u32) MessageBuilder {
            @memset(buf, 0);

            return .{
                .buf = buf,
                .index = 2,
            };
        }

        pub fn push(self: *MessageBuilder, value: u32) void {
            rtt.expect(self.index < self.buf.len);
            self.buf[self.index] = value;
            self.index += 1;
        }

        pub fn getIndex(self: *const MessageBuilder) usize {
            return self.index;
        }

        pub fn finalize(self: *MessageBuilder) void {
            self.push(@backingInt(Tag.end));

            self.buf[0] = @intCast(self.index * @sizeOf(u32));
            self.buf[1] = 0x0000_0000; // process request
        }
    };

    /// Send a single property tag to VideoCore and return the response values.
    pub fn property(dma: DmaAllocator, tag: Tag, values: anytype) Error![values.len]u32 {
        return (try properties(dma, .{ .res = req(tag, values) })).res;
    }

    /// Send multiple property tags in a single message and return the response values.
    ///
    /// The result is a struct that has the same field names as `reqs`,
    /// and each field is the value of the corresponding tag.
    pub fn properties(dma: DmaAllocator, reqs: anytype) Error!Responses(@TypeOf(reqs)) {
        const names = @typeInfo(@TypeOf(reqs)).@"struct".field_names;

        // Allocate DMA buffer to push messages.
        const buf = try dma.allocBytes(4096, .normal);
        defer dma.freeBytes(buf);
        const msg: []u32 = @as([*]u32, @ptrFromInt(buf.cpu))[0 .. buf.size / @sizeOf(u32)];

        // Construct the mailbox message.
        var idx_values: [names.len]usize = undefined;
        var b = MessageBuilder.init(msg);
        inline for (names, 0..) |name, i| {
            const r = @field(reqs, name);
            b.push(@backingInt(r.tag)); // tag
            b.push(r.values.len * @sizeOf(u32)); // size
            b.push(0); // request
            idx_values[i] = b.getIndex();
            inline for (r.values) |value| b.push(value);
        }
        b.finalize();
        dma.syncForDevice(buf.cpu, buf.size);

        // Notify VC of the message.
        call(.prop2vc, @intCast(buf.bus));
        dma.syncForCpu(buf.cpu, buf.size);
        if (!isValidCode(msg[1])) {
            log.err("VC mailbox call failed: response=0x{X}", .{msg[1]});
            return Error.DeviceError;
        }

        // Parse the response.
        var res: Responses(@TypeOf(reqs)) = undefined;
        inline for (names, 0..) |name, i| {
            if (!isValidCode(msg[idx_values[i] - 1])) {
                log.err("VC mailbox tag not processed: {s} code=0x{X}", .{ name, msg[idx_values[i] - 1] });
                return Error.DeviceError;
            }

            const n = @field(reqs, name).values.len;
            @field(res, name) = msg[idx_values[i]..][0..n].*;
        }

        return res;
    }

    /// Create a request of the given tag.
    pub fn req(tag: Tag, values: anytype) Request(values.len) {
        return .{ .tag = tag, .values = values };
    }

    /// A request of a single tag with `n` value words.
    pub fn Request(n: usize) type {
        return struct {
            tag: Tag,
            values: [n]u32,
        };
    }

    /// Type of the response.
    fn Responses(Reqs: type) type {
        const info = @typeInfo(Reqs).@"struct";
        var types: [info.field_names.len]type = undefined;
        for (info.field_types, 0..) |Req, i| {
            types[i] = @FieldType(Req, "values");
        }

        return @Struct(
            .auto,
            null,
            info.field_names,
            &types,
            &@splat(.{}),
        );
    }

    /// Check if the response code is valid.
    fn isValidCode(code: u32) bool {
        return code & 0x8000_0000 != 0;
    }
};

// =============================================================
// Registers
// =============================================================

/// Available mailbox channels.
const Channels = enum(u4) {
    /// Power management.
    pm = 0,
    /// Framebuffer.
    fb = 1,
    /// Virtual UART.
    uart = 2,
    /// VCHIQ (VideoCore Host Interface Queue).
    vchiq = 3,
    /// LEDs.
    leds = 4,
    /// Buttons.
    buttons = 5,
    /// Touchscreen.
    touch = 6,
    /// Unused.
    unused = 7,
    /// Property tags (ARM to VC).
    prop2vc = 8,
    /// Property tags (VC to ARM).
    prop2cpu = 9,
};

const Mbox0Read = packed struct(u32) {
    channel: Channels,
    data: u28,
};

const Mbox0Status = packed struct(u32) {
    _0: u30 = 0,
    empty: bool,
    full: bool,
};

const Mbox1Write = packed struct(u32) {
    channel: Channels,
    data: u28,
};

const Mbox1Status = packed struct(u32) {
    _0: u30 = 0,
    empty: bool,
    full: bool,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.vcmbox);
const common = @import("common");
const rtt = common.rtt;
const DmaAllocator = common.mem.DmaAllocator;
const mmio = common.mmio;
