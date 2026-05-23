pub const dma = @import("dd/dma.zig");
pub const gpio = @import("dd/gpio.zig");
pub const pm = @import("dd/pm.zig");
pub const vcmbox = @import("../rpi5/dd/vcmbox.zig");

pub const FrameBuffer = @import("../rpi5/dd/fb.zig").FrameBuffer(1280, 720);
