//! IDT construction and interrupt dispatch.

/// Number of gates in the IDT.
const num_gates = 256;
/// Alignment of the IDT.
const idt_align = 4 * units.kib;
/// Number of vectors reserved by the CPU for exceptions.
const num_reserved_exceptions = 32;

/// Interrupt handler function signature.
///
/// Returns null if the interrupt cannot be handled.
pub const Handler = *const fn (vector: u64) ?void;

/// Interrupt Descriptor Table.
var idt: Idt align(idt_align) = undefined;
/// Function pointer to the registered interrupt handler.
var handler: ?Handler = null;
/// Called when an exception handler reaches the end.
var terminator: ?*const fn (u8) void = null;

/// Whether we are currently handling an exception.
/// TODO: should be per-CPU.
var in_handling = false;

/// Initialize the IDT for this CPU.
pub fn initLocal() void {
    idt.init();

    // Use the dedicated interrupt stack for the double fault handler
    // so that a stack overflow does not turn into a triple fault.
    idt.setIst(@intFromEnum(Exception.df), 1);

    idt.load();
}

/// Set the console used to print exception information.
pub fn setConsole(c: Console) void {
    console = c;
}

/// Set the terminator function called at the end of exception handlers.
pub fn setTerminator(f: @TypeOf(terminator)) void {
    terminator = f;
}

/// Set the interrupt handler function.
pub fn setHandler(h: Handler) void {
    handler = h;
}

/// Dispatch an interrupt to the registered handler.
///
/// Called from the ISR common stub.
pub fn dispatch(ctx: *Context) void {
    if (ctx.vector >= num_reserved_exceptions) {
        if (handler) |f| {
            if (f(ctx.vector)) |_| {
                return;
            }
        }
    }

    defaultHandler(ctx);
}

// =============================================================
// Default handler
// =============================================================

/// Console instance used to print exception information.
///
/// Must be set by the kernel before any exception occurs.
var console: Console = undefined;

fn defaultHandler(ctx: *Context) void {
    var w = UnsafeWriter.init(console);
    const exception: Exception = @enumFromInt(ctx.vector);

    w.log("", .{});
    w.log("=== Oops! ===============================", .{});
    w.log("Vector: {d} ({s})", .{ ctx.vector, exception.name() });
    w.log("", .{});

    if (in_handling) {
        w.log("!!! Double fault detected !!!", .{});

        if (terminator) |term_fn| {
            term_fn(99);
        }

        while (true) {
            am.hlt();
        }
    }
    in_handling = true;

    // Print exception context.
    w.log("Error Code: 0x{X:0>16}", .{ctx.ec});
    w.log("       RIP: 0x{X:0>16}", .{ctx.rip});
    w.log("        CS: 0x{X:0>16}", .{ctx.cs});
    w.log("    RFLAGS: 0x{X:0>16}", .{ctx.rflags});
    if (ctx.isFromUserMode()) {
        w.log("       RSP: 0x{X:0>16}", .{ctx.rsp});
        w.log("        SS: 0x{X:0>16}", .{ctx.ss});
    }

    w.log("", .{});

    // Print general-purpose registers.
    w.log("Register context:", .{});
    w.log(" RAX: 0x{X:0>16}", .{ctx.rax});
    w.log(" RBX: 0x{X:0>16}", .{ctx.rbx});
    w.log(" RCX: 0x{X:0>16}", .{ctx.rcx});
    w.log(" RDX: 0x{X:0>16}", .{ctx.rdx});
    w.log(" RSI: 0x{X:0>16}", .{ctx.rsi});
    w.log(" RDI: 0x{X:0>16}", .{ctx.rdi});
    w.log(" RBP: 0x{X:0>16}", .{ctx.rbp});
    w.log(" R8 : 0x{X:0>16}", .{ctx.r8});
    w.log(" R9 : 0x{X:0>16}", .{ctx.r9});
    w.log(" R10: 0x{X:0>16}", .{ctx.r10});
    w.log(" R11: 0x{X:0>16}", .{ctx.r11});
    w.log(" R12: 0x{X:0>16}", .{ctx.r12});
    w.log(" R13: 0x{X:0>16}", .{ctx.r13});
    w.log(" R14: 0x{X:0>16}", .{ctx.r14});
    w.log(" R15: 0x{X:0>16}", .{ctx.r15});

    w.log("", .{});

    // Print the stack trace.
    w.log("Stack Trace:", .{});
    var it = StackIterator.init(ctx.rbp);
    var ix: usize = 0;
    while (it.next()) |frame| : (ix += 1) {
        w.log("#{d:0>2}: 0x{X:0>16}", .{ ix, frame });
    }

    // Call the terminator if set.
    if (terminator) |term_fn| {
        term_fn(@truncate(ctx.vector));
    }

    // Halt the CPU.
    while (true) {
        am.hlt();
    }
}

// =============================================================
// IDT
// =============================================================

/// Protected-Mode Exceptions.
const Exception = enum(usize) {
    de = 0,
    db = 1,
    nmi = 2,
    bp = 3,
    of = 4,
    br = 5,
    ud = 6,
    nm = 7,
    df = 8,
    co = 9,
    ts = 10,
    np = 11,
    ss = 12,
    gp = 13,
    pf = 14,
    mf = 16,
    ac = 17,
    mc = 18,
    xm = 19,
    ve = 20,
    cp = 21,

    _,

    /// Get the name of an exception.
    fn name(self: Exception) []const u8 {
        return switch (self) {
            .de => "#DE: Divide by zero",
            .db => "#DB: Debug",
            .nmi => "NMI: Non-maskable interrupt",
            .bp => "#BP: Breakpoint",
            .of => "#OF: Overflow",
            .br => "#BR: Bound range exceeded",
            .ud => "#UD: Invalid opcode",
            .nm => "#NM: Device not available",
            .df => "#DF: Double fault",
            .co => "Coprocessor segment overrun",
            .ts => "#TS: Invalid TSS",
            .np => "#NP: Segment not present",
            .ss => "#SS: Stack-segment fault",
            .gp => "#GP: General protection fault",
            .pf => "#PF: Page fault",
            .mf => "#MF: Floating-point exception",
            .ac => "#AC: Alignment check",
            .mc => "#MC: Machine check",
            .xm => "#XM: SIMD exception",
            .ve => "#VE: Virtualization exception",
            .cp => "#CP: Control protection exception",
            _ => "External interrupt",
        };
    }
};

/// Interrupt Descriptor Table.
const Idt = extern struct {
    _data: [num_gates]GateDesc,

    /// Set all entries to their ISR stub.
    fn init(self: *Idt) void {
        inline for (0..num_gates) |i| {
            self._data[i] = GateDesc.new(
                @intFromPtr(&isr.generateIsr(i)),
                .kernel_cs,
                .interrupt_gate,
                0,
            );
        }
    }

    /// Set the interrupt stack table index for the given vector.
    fn setIst(self: *Idt, vector: usize, ist_index: u3) void {
        self._data[vector].ist = ist_index;
    }

    /// Load this IDT into the IDTR.
    fn load(self: *Idt) void {
        const idtr = Idtr{
            .limit = @sizeOf(@TypeOf(self._data)) - 1,
            .base = &self._data,
        };
        am.lidt(@intFromPtr(&idtr));
    }

    comptime {
        if (@sizeOf(Idt) != 4096) {
            @compileError("IDT size must be 4096 bytes");
        }
    }
};

/// 64-bit mode interrupt/trap gate descriptor.
const GateDesc = packed struct(u128) {
    /// Lower 16 bits of the ISR offset.
    offset_low: u16,
    /// Segment selector, must point to a valid code segment in the GDT.
    seg_selector: u16,
    /// Interrupt Stack Table index. If 0, the processor does not switch stacks.
    ist: u3 = 0,
    /// Reserved.
    _35: u5 = 0,
    /// Gate type.
    gate_type: Type,
    /// Reserved.
    _44: u1 = 0,
    /// Descriptor Privilege Level required to call the ISR via the INT instruction.
    ///
    /// Hardware interrupts ignore this field.
    dpl: u2,
    /// Present flag. Must be 1.
    present: bool = true,
    /// Middle 16 bits of the ISR offset.
    offset_middle: u16,
    /// Higher 32 bits of the ISR offset.
    offset_high: u32,
    /// Reserved.
    _96: u32 = 0,

    /// Gate type.
    const Type = enum(u4) {
        /// Interrupt gate. Clears the IF flag when called.
        interrupt_gate = 0b1110,
        /// Trap gate. Does not clear the IF flag when called.
        trap_gate = 0b1111,
        _,
    };

    fn new(offset: u64, index: gdt.SegIndex, gate_type: Type, dpl: u2) GateDesc {
        return .{
            .offset_low = @truncate(offset),
            .seg_selector = @bitCast(gdt.SegSel{ .rpl = 0, .index = index }),
            .gate_type = gate_type,
            .dpl = dpl,
            .offset_middle = @truncate(offset >> 16),
            .offset_high = @truncate(offset >> 32),
        };
    }
};

/// IDT Register.
const Idtr = extern struct {
    /// The size of the IDT in bytes minus 1.
    limit: u16,
    /// The physical base address of the IDT.
    base: *[num_gates]GateDesc align(1),
};

// =============================================================
// Register context
// =============================================================

/// Register context saved by the ISR common stub on interrupt entry.
///
/// Layout must match the push order in `isr.zig`.
pub const Context = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rax: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,

    /// Interrupt vector, pushed by the ISR stub.
    vector: u64,
    /// Error code, pushed by the CPU or the ISR stub.
    ec: u64,

    // =============================================================
    // Pushed by the CPU on interrupt entry.

    rip: u64,
    cs: u64,
    rflags: u64,

    // =============================================================
    /// Valid only when the interrupt was taken from user mode.
    ///
    rsp: u64,
    ss: u64,

    /// Check if the interrupt was taken from user mode.
    pub fn isFromUserMode(self: Context) bool {
        return (self.cs & 0b11) == 0b11;
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const units = common.units;
const Console = common.Console;
const UnsafeWriter = common.UnsafeWriter;
const am = @import("asm.zig");
const gdt = @import("gdt.zig");
const isr = @import("isr.zig");
const StackIterator = @import("StackIterator.zig");
