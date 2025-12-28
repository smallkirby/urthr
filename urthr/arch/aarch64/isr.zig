/// Exception table defined in `isr.S`.
extern const exception_table: *void;

/// Whether we are currently handling an exception.
/// TODO: should be per-CPU.
var in_handling: bool = false;

/// Initialize exception handling for this CPU.
pub fn initLocal() void {
    am.msr(.vbar_el1, .{ .addr = @intFromPtr(&exception_table) });

    am.isb();
}

/// Set the console used to print exception information.
pub fn setConsole(c: Console) void {
    console = c;
}

// =============================================================
// Exception handlers
// =============================================================

/// Serial writer that does not take a lock to prevent deadlock.
pub const UnsafeWriter = struct {
    writer: std.Io.Writer = .{
        .vtable = &writer_vtable,
        .buffer = &.{},
    },

    const writer_vtable = std.Io.Writer.VTable{
        .drain = drain,
    };

    fn drain(_: *std.Io.Writer, data: []const []const u8, _: usize) !usize {
        var written: usize = 0;
        for (data) |bytes| {
            written += console.print(bytes);
        }
        return written;
    }

    pub fn new() UnsafeWriter {
        return .{};
    }

    pub fn log(self: *UnsafeWriter, comptime fmt: []const u8, args: anytype) void {
        self.writer.print(fmt ++ "\n", args) catch {};
    }
};

/// Console instance used to print exception information.
///
/// Must be set by the kernel before any exception occurs.
var console: Console = undefined;

fn defaultHandler(ctx: *Context, comptime kind: []const u8) void {
    var w = UnsafeWriter.new();

    w.log("", .{});
    w.log("=== Oops! ===============================", .{});
    w.log("Type: {s}", .{kind});
    w.log("", .{});

    if (in_handling) {
        w.log("!!! Double fault detected !!!", .{});

        while (true) {
            am.wfe();
        }
    }
    in_handling = true;

    // Print system registers.
    const esr = am.mrs(.esr_el1);
    w.log(" ESR_EL1 : 0x{X:0>16}", .{am.mrsi(.esr_el1)});
    w.log("   Class : {X:0>2} ({s})", .{ @intFromEnum(esr.ec), @tagName(esr.ec) });
    w.log("    ISS1 : {X:0>7}", .{esr.iss});
    w.log("    ISS2 : {X:0>7}", .{esr.iss2});
    w.log(" ELR_EL1 : 0x{X:0>16}", .{am.mrsi(.elr_el1)});
    w.log("SPSR_EL1 : 0x{X:0>16}", .{am.mrsi(.spsr_el1)});
    w.log(" FAR_EL1 : 0x{X:0>16}", .{am.mrsi(.far_el1)});

    w.log("", .{});

    // Print general-purpose registers.
    w.log("Register context:", .{});
    w.log("  x0: 0x{X:0>16}", .{ctx.x0});
    w.log("  x1: 0x{X:0>16}", .{ctx.x1});
    w.log("  x2: 0x{X:0>16}", .{ctx.x2});
    w.log("  x3: 0x{X:0>16}", .{ctx.x3});
    w.log("  x4: 0x{X:0>16}", .{ctx.x4});
    w.log("  x5: 0x{X:0>16}", .{ctx.x5});
    w.log("  x6: 0x{X:0>16}", .{ctx.x6});
    w.log("  x7: 0x{X:0>16}", .{ctx.x7});
    w.log("  x8: 0x{X:0>16}", .{ctx.x8});
    w.log("  x9: 0x{X:0>16}", .{ctx.x9});
    w.log(" x10: 0x{X:0>16}", .{ctx.x10});
    w.log(" x11: 0x{X:0>16}", .{ctx.x11});
    w.log(" x12: 0x{X:0>16}", .{ctx.x12});
    w.log(" x13: 0x{X:0>16}", .{ctx.x13});
    w.log(" x14: 0x{X:0>16}", .{ctx.x14});
    w.log(" x15: 0x{X:0>16}", .{ctx.x15});
    w.log(" x16: 0x{X:0>16}", .{ctx.x16});
    w.log(" x17: 0x{X:0>16}", .{ctx.x17});
    w.log(" x18: 0x{X:0>16}", .{ctx.x18});
    w.log(" x19: 0x{X:0>16}", .{ctx.x19});
    w.log(" x20: 0x{X:0>16}", .{ctx.x20});
    w.log(" x21: 0x{X:0>16}", .{ctx.x21});
    w.log(" x22: 0x{X:0>16}", .{ctx.x22});
    w.log(" x23: 0x{X:0>16}", .{ctx.x23});
    w.log(" x24: 0x{X:0>16}", .{ctx.x24});
    w.log(" x25: 0x{X:0>16}", .{ctx.x25});
    w.log(" x26: 0x{X:0>16}", .{ctx.x26});
    w.log(" x27: 0x{X:0>16}", .{ctx.x27});
    w.log(" x28: 0x{X:0>16}", .{ctx.x28});
    w.log(" x29: 0x{X:0>16}", .{ctx.x29});
    w.log(" x30: 0x{X:0>16}", .{ctx.x30});

    w.log("", .{});

    // Print the stack trace.
    w.log("Stack Trace:", .{});
    var it = std.debug.StackIterator.init(null, ctx.x29);
    var ix: usize = 0;
    while (it.next()) |frame| : (ix += 1) {
        w.log("#{d:0>2}: 0x{X:0>16}", .{ ix, frame });
    }

    // Halt the CPU.
    while (true) {
        am.wfe();
    }
}

// =============================================================
// Exceptions stubs
// =============================================================

export fn syncCurElSp0(ctx: *Context) callconv(.c) void {
    return defaultHandler(ctx, "Synchronous, Current EL, SP_EL0");
}

export fn irqCurElSp0(ctx: *Context) callconv(.c) void {
    return defaultHandler(ctx, "IRQ, Current EL, SP_EL0");
}

export fn fiqCurElSp0(ctx: *Context) callconv(.c) void {
    return defaultHandler(ctx, "FIQ, Current EL, SP_EL0");
}

export fn serrorCurElSp0(ctx: *Context) callconv(.c) void {
    return defaultHandler(ctx, "SError, Current EL, SP_EL0");
}

export fn syncCurElSpx(ctx: *Context) callconv(.c) void {
    return defaultHandler(ctx, "Synchronous, Current EL, SP_ELx");
}

export fn irqCurElSpx(ctx: *Context) callconv(.c) void {
    return defaultHandler(ctx, "IRQ, Current EL, SP_ELx");
}

export fn fiqCurElSpx(ctx: *Context) callconv(.c) void {
    return defaultHandler(ctx, "FIQ, Current EL, SP_ELx");
}

export fn serrorCurElSpx(ctx: *Context) callconv(.c) void {
    return defaultHandler(ctx, "SError, Current EL, SP_ELx");
}

export fn syncLowerElA64(ctx: *Context) callconv(.c) void {
    return defaultHandler(ctx, "Synchronous, Lower EL, A64");
}

export fn irqLowerElA64(ctx: *Context) callconv(.c) void {
    return defaultHandler(ctx, "IRQ, Lower EL, A64");
}

export fn fiqLowerElA64(ctx: *Context) callconv(.c) void {
    return defaultHandler(ctx, "FIQ, Lower EL, A64");
}

export fn serrorLowerElA64(ctx: *Context) callconv(.c) void {
    return defaultHandler(ctx, "SError, Lower EL, A64");
}

export fn syncLowerElA32(ctx: *Context) callconv(.c) void {
    return defaultHandler(ctx, "Synchronous, Lower EL, A32");
}

export fn irqLowerElA32(ctx: *Context) callconv(.c) void {
    return defaultHandler(ctx, "IRQ, Lower EL, A32");
}

export fn fiqLowerElA32(ctx: *Context) callconv(.c) void {
    return defaultHandler(ctx, "FIQ, Lower EL, A32");
}

export fn serrorLowerElA32(ctx: *Context) callconv(.c) void {
    return defaultHandler(ctx, "SError, Lower EL, A32");
}

/// Register context.
pub const Context = extern struct {
    x0: u64,
    x1: u64,
    x2: u64,
    x3: u64,
    x4: u64,
    x5: u64,
    x6: u64,
    x7: u64,
    x8: u64,
    x9: u64,
    x10: u64,
    x11: u64,
    x12: u64,
    x13: u64,
    x14: u64,
    x15: u64,
    x16: u64,
    x17: u64,
    x18: u64,
    x19: u64,
    x20: u64,
    x21: u64,
    x22: u64,
    x23: u64,
    x24: u64,
    x25: u64,
    x26: u64,
    x27: u64,
    x28: u64,
    x29: u64,
    x30: u64,
    _pad: u64,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const Console = common.Console;
const am = @import("asm.zig");
const regs = @import("register.zig");
