//! Framebuffer driver for Raspberry Pi via VideoCore mailbox property channel.

pub fn FrameBuffer(width: usize, height: usize) type {
    return struct {
        pub const Error = IoAllocator.Error || props.Error || error{MailboxError};

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
        var console: FbConsole = undefined;

        // =============================================================
        // API
        // =============================================================

        /// Initialize the framebuffer.
        pub fn init(io: IoAllocator, dma: DmaAllocator, vt: Framebuffer.VTable) Error!void {
            // ref. https://github.com/raspberrypi/firmware/wiki/Mailbox-property-interface
            const res = try props.properties(dma, .{
                // Set physical (display) width / height
                .phys_wh = req(.set_phys_wh, .{ fb.width, fb.height }),
                // Set virtual (buffer) width / height
                .virt_wh = req(.set_virt_wh, .{ fb.width, fb.height }),
                // Set virtual offset.
                .virt_off = req(.set_virt_off, .{ 0, 0 }),
                // Set depth.
                .depth = req(.set_depth, .{32}),
                // Set pixel order.
                .pixel_order = req(.set_pixel_order, .{0}),
                // Allocate buffer.
                .alloc = req(.alloc_buf, .{ 4096, 0 }), // req: alignment, res: base address and size
                // Get pitch.
                .pitch = req(.get_pitch, .{0}),
            });

            // Set the allocated framebuffer.
            const fb_phys: usize = res.alloc[0];
            const fb_size: usize = res.alloc[1];
            const pitch = res.pitch[0];

            if (fb_phys == 0 or fb_size == 0) {
                log.err("framebuffer allocation failed: addr=0x{X} size=0x{X}", .{ fb_phys, fb_size });
                return Error.MailboxError;
            }
            const aligned_phys = std.mem.alignBackward(usize, fb_phys, urd.mem.page_size);
            const aligned_size = std.mem.alignForward(usize, fb_size, urd.mem.page_size);
            const aligned_offset = fb_phys - aligned_phys;

            fb.phys = fb_phys;
            fb.base = try io.ioremap(
                aligned_phys,
                aligned_size,
                .wc,
            ) + aligned_offset;
            fb.pitch = pitch;

            // The firmware seems to ignore the requested depth and just use config.txt setting.
            // ref. https://github.com/raspberrypi/firmware/issues/1904
            const bpp = pitch / fb.width;
            const format: Framebuffer.PixelFormat = switch (bpp) {
                2 => .rgb565,
                4 => .bgrx8888,
                else => {
                    log.err("unsupported framebuffer pitch: {d}", .{pitch});
                    return Error.MailboxError;
                },
            };

            // Create a framebuffer console.
            console = FbConsole.init(.{
                .ctx = &console,
                .vtable = vt,
                .base = fb.base,
                .phys = fb.phys,
                .size = fb_size,
                .width = fb.width,
                .height = fb.height,
                .pitch = fb.pitch,
                .format = format,
            });

            log.info(
                "phys=0x{X} size=0x{X} pitch={d} {d}x{d} {d}bpp",
                .{ fb_phys, fb_size, pitch, fb.width, fb.height, bpp * 8 },
            );
        }

        /// Get a Console wrapping the framebuffer.
        pub fn getConsole() common.Console {
            return console.interface();
        }

        /// Get the framebuffer backing the console.
        pub fn getFramebuffer() Framebuffer {
            return console.fb;
        }
    };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.fb);
const common = @import("common");
const DmaAllocator = common.mem.DmaAllocator;
const IoAllocator = common.mem.IoAllocator;
const FbConsole = common.FbConsole;
const Framebuffer = common.Framebuffer;
const urd = @import("urthr");
const vcmbox = @import("vcmbox.zig");
const props = vcmbox.props;
const req = props.req;
