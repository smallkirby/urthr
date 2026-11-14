/// Trap vector.
extern fn trap_vector() void;

/// Context of the interrupt being handled on this core.
var irq_ctx: ?*const Context linksection(common.pcpu.section) = null;

/// Called when an exception handler reaches the end.
var terminator: ?*const fn (u8) void = null;
/// Function pointer to the registered interrupt handler.
var handler: ?HandlerSignature = null;
/// Hook called before returning to U-mode.
var eret_hook: ?EreturnHook = null;
/// Function pointer to the registered page fault handler.
var pagefault_handler: ?PageFaultHandler = null;
/// Function pointer to the registered user fault handler.
var userfault_handler: ?UserFaultHandler = null;

/// Exception handler function signature.
///
/// Returns null if the exception cannot be handled.
pub const HandlerSignature = *const fn () ?void;

/// Page fault handler function signature.
///
/// Returns true if the fault was handled.
/// In that case, the faulting instruction can be safely retried,
/// or a signal has been queued for delivery).
///
/// Returns false if the fault is unrecoverable.
pub const PageFaultHandler = *const fn (far: usize, access: common.mem.AccessType, user: bool) bool;

/// User mode fault kinds.
pub const UserFault = enum {};

/// User fault handler function signature.
///
/// Called for synchronous exceptions taken from EL0, other than data aborts and SVC.
pub const UserFaultHandler = *const fn (kind: UserFault, addr: usize) void;

/// Hook function signature called before returning to U-mode.
pub const EreturnHook = *const fn (ctx: *Context) void;

/// Initialize exception handling for this CPU.
pub fn initLocal() void {
    const stvec = regs.Stvec{
        .mode = .direct,
        .base = @intCast(@intFromPtr(&trap_vector) >> 2),
    };
    am.csrw(.stvec, stvec);

    // Check if the value has been accepted.
    rtt.expectEqual(stvec, am.csrr(.stvec));
}

/// Set the console used to print exception information.
pub fn setConsole(c: Console) void {
    console = c;
}

/// Set the terminator function called at the end of exception handlers.
pub fn setTerminator(f: *const fn (u8) void) void {
    terminator = f;
}

/// Set the interrupt handler function.
pub fn setHandler(h: HandlerSignature) void {
    handler = h;
}

/// Set the page fault handler function.
pub fn setPageFaultHandler(h: PageFaultHandler) void {
    pagefault_handler = h;
}

/// Set the user fault handler function.
pub fn setUserFaultHandler(h: UserFaultHandler) void {
    userfault_handler = h;
}

/// Set hook called before returning to U-mode.
pub fn setEreturnHook(f: EreturnHook) void {
    eret_hook = f;
}

/// Call the registered ERET hook, if any.
pub fn callEreturnHook(ctx: *Context) void {
    if (eret_hook) |f| f(ctx);
}

/// Get the state of the thread interrupted by an IRQ.
///
/// Available only while handling an IRQ.
pub fn getInterruptedInfo() ?common.arch.InterruptedInfo {
    const ctx = getIrqContext() orelse return null;
    const sstatus: regs.Sstatus = @bitCast(ctx.sstatus);
    return .{
        .pc = ctx.sepc,
        .fp = ctx.s0,
        .user = sstatus.spp == .user,
    };
}

/// Get the interrupt code of the IRQ being handled on this core.
///
/// Available only while handling an IRQ.
pub fn getIrqCode() u64 {
    const ctx = getIrqContext() orelse @panic("Not in IRQ context.");
    rtt.expectEqual(true, ctx.scause.interrupt);
    return ctx.scause.code.raw();
}

/// Get the address of a per-CPU variable for the current core.
inline fn percpu(comptime v: anytype) @TypeOf(v) {
    return common.pcpu.ptrAt(arch.getPerCpuBase(), v);
}

inline fn getIrqContext() ?*const Context {
    return percpu(&irq_ctx).*;
}

inline fn setIrqContext(ctx: ?*const Context) ?*const Context {
    const prev = getIrqContext();
    percpu(&irq_ctx).* = ctx;
    return prev;
}

/// Register context.
pub const Context = extern struct {
    ra: u64,
    sp: u64,
    gp: u64,
    tp: u64,
    t0: u64,
    t1: u64,
    t2: u64,
    t3: u64,
    t4: u64,
    t5: u64,
    t6: u64,
    s0: u64,
    s1: u64,
    s2: u64,
    s3: u64,
    s4: u64,
    s5: u64,
    s6: u64,
    s7: u64,
    s8: u64,
    s9: u64,
    s10: u64,
    s11: u64,
    a0: u64,
    a1: u64,
    a2: u64,
    a3: u64,
    a4: u64,
    a5: u64,
    a6: u64,
    a7: u64,

    sepc: u64,
    sstatus: regs.Sstatus,
    scause: regs.Scause,
    stval: u64,

    _pad0: u64 = 0,

    comptime {
        std.debug.assert(@sizeOf(Context) % 16 == 0);
    }
};

// =============================================================
// Trap handlers
// =============================================================

/// Console instance used to print exception information.
///
/// Must be set by the kernel before any exception occurs.
var console: Console = undefined;

/// Entry point of traps.
export fn handleTrap(ctx: *Context) callconv(.c) void {
    const cause: regs.Scause = @bitCast(ctx.scause);

    if (cause.interrupt) {
        const prev = setIrqContext(ctx);
        defer _ = setIrqContext(prev);

        if (handler) |f| {
            if (f()) |_| {
                return;
            }
        }
        return defaultHandler(ctx, "Interrupt");
    } else {
        return switch (cause.code.e) {
            .ecall_u => svc.ecall(ctx),
            else => defaultHandler(ctx, "Exception"),
        };
    }
}

/// Default trap handler.
fn defaultHandler(ctx: *Context, comptime kind: []const u8) noreturn {
    var w = UnsafeWriter.init(console);

    w.log("", .{});
    w.log("=== Oops! ===============================", .{});
    w.log("Type: {s}", .{kind});
    w.log("", .{});

    // Print CSRs.
    w.log("  SCAUSE : 0x{X:0>16}", .{@as(u64, @bitCast(ctx.scause))});
    w.log("    SEPC : 0x{X:0>16}", .{ctx.sepc});
    w.log("   STVAL : 0x{X:0>16}", .{ctx.stval});
    w.log(" SSTATUS : 0x{X:0>16}", .{@as(u64, @bitCast(ctx.sstatus))});

    // Print GPRs.
    w.log("", .{});
    w.log("Register context:", .{});
    w.log("  ra: 0x{X:0>16}", .{ctx.ra});
    w.log("  sp: 0x{X:0>16}", .{ctx.sp});
    w.log("  gp: 0x{X:0>16}", .{ctx.gp});
    w.log("  tp: 0x{X:0>16}", .{ctx.tp});
    w.log("  t0: 0x{X:0>16}", .{ctx.t0});
    w.log("  t1: 0x{X:0>16}", .{ctx.t1});
    w.log("  t2: 0x{X:0>16}", .{ctx.t2});
    w.log("  t3: 0x{X:0>16}", .{ctx.t3});
    w.log("  t4: 0x{X:0>16}", .{ctx.t4});
    w.log("  t5: 0x{X:0>16}", .{ctx.t5});
    w.log("  t6: 0x{X:0>16}", .{ctx.t6});
    w.log("  s0: 0x{X:0>16}", .{ctx.s0});
    w.log("  s1: 0x{X:0>16}", .{ctx.s1});
    w.log("  s2: 0x{X:0>16}", .{ctx.s2});
    w.log("  s3: 0x{X:0>16}", .{ctx.s3});
    w.log("  s4: 0x{X:0>16}", .{ctx.s4});
    w.log("  s5: 0x{X:0>16}", .{ctx.s5});
    w.log("  s6: 0x{X:0>16}", .{ctx.s6});
    w.log("  s7: 0x{X:0>16}", .{ctx.s7});
    w.log("  s8: 0x{X:0>16}", .{ctx.s8});
    w.log("  s9: 0x{X:0>16}", .{ctx.s9});
    w.log(" s10: 0x{X:0>16}", .{ctx.s10});
    w.log(" s11: 0x{X:0>16}", .{ctx.s11});
    w.log("  a0: 0x{X:0>16}", .{ctx.a0});
    w.log("  a1: 0x{X:0>16}", .{ctx.a1});
    w.log("  a2: 0x{X:0>16}", .{ctx.a2});
    w.log("  a3: 0x{X:0>16}", .{ctx.a3});
    w.log("  a4: 0x{X:0>16}", .{ctx.a4});
    w.log("  a5: 0x{X:0>16}", .{ctx.a5});
    w.log("  a6: 0x{X:0>16}", .{ctx.a6});
    w.log("  a7: 0x{X:0>16}", .{ctx.a7});

    w.log("", .{});

    // Print the stack trace.
    w.log("Stack Trace:", .{});
    w.log("#00: 0x{X:0>16}", .{ctx.sepc});
    var it = StackIterator.init(ctx.s0);
    var ix: usize = 1;
    while (it.next()) |frame| : (ix += 1) {
        w.log("#{d:0>2}: 0x{X:0>16}", .{ ix, frame });
    }

    // Call the terminator if set.
    if (terminator) |term_fn| {
        term_fn(3);
    }

    // Halt the CPU.
    while (true) {
        asm volatile ("wfi");
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const rtt = common.rtt;
const Console = common.Console;
const UnsafeWriter = common.UnsafeWriter;
const am = @import("asm.zig");
const arch = @import("arch.zig");
const regs = @import("register.zig");
const svc = @import("svc.zig");
const StackIterator = @import("StackIterator.zig");
