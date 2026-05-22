//! Framebuffer driver for Raspberry Pi via VideoCore mailbox property channel.

pub fn FrameBuffer(width: usize, height: usize) type {
    return struct {
        pub const Error = IoAllocator.Error || PageAllocator.Error || error{MailboxError};

        const Self = @This();

        /// Width in pixels.
        width: u32,
        /// Height in pixels.
        height: u32,

        /// Base physical address of the framebuffer.
        phys: usize,
        /// Base virtual address of the framebuffer.
        base: usize,
        /// Number of bytes per scanline.
        pitch: u32,

        /// Framebuffer instance.
        var fb = std.mem.zeroInit(Self, .{
            .width = width,
            .height = height,
        });

        /// Text console backed by the framebuffer.
        var console: common.FbConsole = undefined;

        // =============================================================
        // API
        // =============================================================

        /// Initialize the framebuffer.
        pub fn init(io: IoAllocator, page: PageAllocator) Error!void {
            const buf = try page.allocPagesV(1);
            defer page.freePagesV(buf);

            const msg: []u32 = @as([*]u32, @ptrCast(@alignCast(buf.ptr)))[0 .. buf.len / 4];
            const msg_phys: u32 = @truncate(@intFromPtr(page.translateP(buf.ptr)));

            // Build mailbox messages.
            //
            // ref. https://github.com/raspberrypi/firmware/wiki/Mailbox-property-interface
            const idx_alloc_res = 28;
            const idx_pitch_res = 33;
            {
                var b = MessageBuilder.init(msg);

                // Set physical (display) width / height
                b.push(tags.set_phys_wh);
                b.push(8); // size
                b.push(0); // request
                b.push(fb.width); // req: width
                b.push(fb.height); // req: height
                rtt.expectEqual(7, b.index);

                // Set virtual (buffer) width / height
                b.push(tags.set_virt_wh);
                b.push(8); // size
                b.push(0); // request
                b.push(fb.width); // req: width
                b.push(fb.height); // req: height
                rtt.expectEqual(12, b.index);

                // Set virtual offset.
                b.push(tags.set_virt_off);
                b.push(8); // size
                b.push(0); // request
                b.push(0); // req: x offset
                b.push(0); // req: y offset
                rtt.expectEqual(17, b.index);

                // Set depth.
                // Depth is the number of bits per pixel.
                b.push(tags.set_depth);
                b.push(4); // size
                b.push(0); // request
                b.push(32); // req: depth (RGBX8888)
                rtt.expectEqual(21, b.index);

                // Set pixel order.
                b.push(tags.set_pixel_order);
                b.push(4); // size
                b.push(0); // request
                b.push(1); // req: RGB
                rtt.expectEqual(25, b.index);

                // Allocate buffer.
                b.push(tags.alloc_buf);
                b.push(8); // size
                b.push(0); // request
                rtt.expectEqual(idx_alloc_res, b.index);
                b.push(4096); // req: alignment, res: base address
                b.push(0); // res: size
                rtt.expectEqual(30, b.index);

                // Get pitch.
                b.push(tags.get_pitch);
                b.push(4); // size
                b.push(0); // request
                rtt.expectEqual(idx_pitch_res, b.index);
                b.push(0); // res: pitch
                rtt.expectEqual(34, b.index);

                b.finalize();
            }

            // Flush the message buffer.
            sync.cleanData(buf);

            // Send the message to VideoCore and wait for the response.
            vcmbox.call(.prop2vc, msg_phys);

            // Invalidate cache lines.
            sync.invalidateData(buf);

            if (msg[1] != 0x8000_0000) {
                log.err("mailbox call failed: response=0x{X}", .{msg[1]});
                return Error.MailboxError;
            }

            // Set the allocated framebuffer.
            const fb_phys: usize = msg[idx_alloc_res];
            const fb_size: usize = msg[idx_alloc_res + 1];
            const pitch = msg[idx_pitch_res];

            if (fb_phys == 0 or fb_size == 0) {
                log.err("framebuffer allocation failed: addr=0x{X} size=0x{X}", .{ fb_phys, fb_size });
                return Error.MailboxError;
            }
            const aligned_phys = std.mem.alignBackward(usize, fb_phys, urd.mem.page_size);
            const aligned_size = std.mem.alignForward(usize, fb_size, urd.mem.page_size);
            const aligned_offset = fb_phys - aligned_phys;

            fb.phys = fb_phys;
            fb.base = try io.ioremap(aligned_phys, aligned_size) + aligned_offset;
            fb.pitch = pitch;

            // Create a framebuffer console.
            console = common.FbConsole.init(
                fb.base,
                fb.pitch,
                fb.width,
                fb.height,
            );
        }

        /// Get a Console wrapping the framebuffer.
        pub fn getConsole() common.Console {
            return console.interface();
        }

        // =============================================================
        // Property message layout
        // =============================================================

        // Tag IDs.
        const tags = struct {
            /// End tag.
            const end: u32 = 0x0000_0000;
            /// Allocate buffer.
            const alloc_buf: u32 = 0x0004_0001;
            /// Get pitch.
            const get_pitch: u32 = 0x0004_0008;
            /// Set physical (display) width / height
            const set_phys_wh: u32 = 0x0004_8003;
            /// Set virtual (buffer) width / height
            const set_virt_wh: u32 = 0x0004_8004;
            /// Set depth.
            const set_depth: u32 = 0x0004_8005;
            /// Set pixel order.
            const set_pixel_order: u32 = 0x0004_8006;
            /// Set virtual offset.
            const set_virt_off: u32 = 0x0004_8009;
        };

        /// Utility struct to build mailbox messages.
        const MessageBuilder = struct {
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
                self.buf[self.index] = value;
                self.index += 1;
            }

            pub fn finalize(self: *MessageBuilder) void {
                self.push(tags.end);

                self.buf[0] = @intCast(self.index * @sizeOf(u32));
                self.buf[1] = 0x0000_0000; // process request
            }
        };
    };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.fb);
const common = @import("common");
const rtt = common.rtt;
const IoAllocator = common.mem.IoAllocator;
const PageAllocator = common.mem.PageAllocator;
const urd = @import("urthr");
const sync = @import("../sync.zig");
const vcmbox = @import("vcmbox.zig");
