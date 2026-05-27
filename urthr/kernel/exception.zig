pub const Error = error{
    /// An interrupt handler is already registered for the given vector.
    AlreadyRegistered,
    /// The given interrupt vector is invalid.
    InvalidVector,
    /// Out of memory.
    OutOfMemory,
};

/// Interrupt handler function signature.
pub const Handler = *const fn (id: Vector) void;

/// Interrupt vector number.
pub const Vector = u64;

/// Number of supported fixed-size exceptions.
const num_interrupts = 512;
/// The first interrupt vector for large interrupts.
const large_interrupts_start = 8192;

/// Interrupt handlers for fixed-size exceptions.
var handlers: [num_interrupts]?Handler = [_]?Handler{null} ** num_interrupts;
/// Interrupt handlers for large exceptions.
var large_handlers: LargeIrq.Tree = .{};

/// Initialize IRQ handling common to all CPUs.
///
/// IRQs are not enabled yet.
pub fn initGlobal() void {
    // Set console for exception handlers.
    arch.exception.setConsole(urd.console.getUnsafeConsole());

    // Set terminator function.
    arch.exception.setTerminator(urd.eol);

    // Initialize board-specific IRQ handling.
    board.initIrqGlobal(call);
}

/// Initialize local IRQ handling for the current core.
///
/// IRQs are still masked at this point.
pub fn initLocal() urd.mem.Error!void {
    try board.initIrqLocal();
}

/// Call the registered interrupt handler for the given vector.
///
/// Returns null if no handler is registered.
fn call(vector: Vector) ?void {
    switch (getExceptionType(vector)) {
        .fixed => if (handlers[vector]) |handler| {
            handler(@intCast(vector));
        } else {
            log.warn("No handler registered for interrupt vector: {}", .{vector});
            return null;
        },

        .large => if (large_handlers.find(vector)) |irq| {
            irq.container().handler(@intCast(vector));
        } else {
            log.warn("No handler registered for large interrupt vector: {}", .{vector});
            return null;
        },

        .invalid => {
            log.warn("Received invalid interrupt vector: {}", .{vector});
            return null;
        },
    }
}

/// Set an interrupt handler for the given vector.
///
/// Fails if a handler is already registered for the vector.
pub fn setHandler(vector: Vector, handler: Handler) Error!void {
    switch (getExceptionType(vector)) {
        .fixed => {
            if (handlers[vector] != null) {
                return Error.AlreadyRegistered;
            }
            handlers[vector] = handler;
        },

        .large => {
            if (large_handlers.contains(vector)) {
                return Error.AlreadyRegistered;
            }
            const irq = try urd.mem.bin.create(LargeIrq);
            irq.* = .{ .vector = vector, .handler = handler };
            large_handlers.insert(irq);
        },

        .invalid => return Error.InvalidVector,
    }
}

// =============================================================
// Internals
// =============================================================

const ExceptionType = enum {
    /// Fixed-size exceptions.
    fixed,
    /// Large exceptions.
    large,
    /// Invalid vector.
    invalid,
};

/// Get the type of exception for the given vector.
fn getExceptionType(vector: Vector) ExceptionType {
    if (vector < num_interrupts) {
        return .fixed;
    } else if (large_interrupts_start <= vector) {
        return .large;
    } else {
        return .invalid;
    }
}

/// Exception that is assigned a large exception vector.
const LargeIrq = struct {
    /// Exception vector.
    vector: Vector,
    /// Handler function.
    handler: Handler,
    /// Tree node.
    _rbnode: Tree.Node = .init,

    const Tree = RbTree(LargeIrq, "_rbnode", cmp, cmpByKey);

    fn cmp(a: *const LargeIrq, b: *const LargeIrq) std.math.Order {
        if (a.vector < b.vector) return .lt;
        if (a.vector > b.vector) return .gt;
        return .eq;
    }

    fn cmpByKey(key: Vector, a: *const LargeIrq) std.math.Order {
        if (a.vector < key) return .lt;
        if (a.vector > key) return .gt;
        return .eq;
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.exception);
const RbTree = @import("common").RbTree;
const board = @import("board").impl;
const arch = @import("arch").impl;
const urd = @import("urthr");
