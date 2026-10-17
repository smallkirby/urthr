/// The number of signals supported.
pub const num_signals = 64;

/// Integer type for signal numbers.
const SigInt = u32;

/// Signal numbers.
///
/// POSIX-compliant.
pub const Signal = enum(SigInt) {
    /// Hangup detected on controlling terminal or death of controlling process.
    hang = 1,
    /// Interrupt from keyboard.
    interrupt = 2,
    /// Quit from keyboard.
    quit = 3,
    /// Kill signal.
    kill = 9,
    /// Segmentation fault.
    segv = 11,
    /// Broken pipe.
    pipe = 13,
    /// Timer signal from alarm.
    alarm = 14,
    /// Termination signal.
    term = 15,
    /// Child stopped or terminated.
    child = 17,
    /// Continue if stopped.
    cont = 18,
    /// Stop process.
    stop = 19,
    /// Terminal stop signal.
    tstp = 20,
    /// Background process attempting read.
    ttin = 21,
    /// Background process attempting write.
    ttou = 22,

    _,
};
comptime {
    for (std.enums.values(Signal)) |sig| {
        urd.comptimeAssert(@backingInt(sig) <= num_signals, "Invalid signal number.", .{});
    }
}

/// Bit mask type for signal sets.
pub const Mask = u64;
comptime {
    urd.comptimeAssert(@bitSizeOf(Mask) >= num_signals, "Mask type is too small.", .{});
}

/// Signal action descriptor.
pub const Action = struct {
    /// User-space handler address.
    handler: usize = sig_default,
    /// Additional signals to block while the handler runs.
    mask: Mask = 0,
    /// SA_* flags.
    flags: u32 = 0,

    /// Use default action for the given signal number.
    const sig_default: usize = 0;
    /// Ignore the given signal number.
    const sig_ignore: usize = 1;
};

/// Per-signal action table.
///
/// Might be shared by threads.
pub const Handlers = struct {
    /// Reference count.
    ///
    /// Freed when it drops to zero.
    refcnt: usize = 1,
    /// Per-signal action table (0-origin).
    actions: [num_signals]Action = @splat(.{}),

    /// Create a new, default-initialized handler table.
    pub fn new(allocator: Allocator) Allocator.Error!*Handlers {
        const self = try allocator.create(Handlers);
        self.* = .{};
        return self;
    }

    /// Create an independent copy of this handler table.
    pub fn clone(self: *const Handlers, allocator: Allocator) Allocator.Error!*Handlers {
        const new_handlers = try allocator.create(Handlers);
        new_handlers.* = .{ .actions = self.actions };
        return new_handlers;
    }

    /// Create a handler table for forked process.
    ///
    /// Only ignored signals are preserved.
    pub fn reset(self: *const Handlers, allocator: Allocator) Allocator.Error!*Handlers {
        const new_handlers = try allocator.create(Handlers);
        new_handlers.* = .{};
        for (self.actions, 0..) |action, i| {
            if (action.handler == Action.sig_ignore) {
                new_handlers.actions[i].handler = Action.sig_ignore;
            }
        }
        return new_handlers;
    }

    /// Increment the reference count to share this handler table.
    pub fn ref(self: *Handlers) *Handlers {
        self.refcnt += 1;
        return self;
    }

    /// Decrement the reference count, freeing the table when it reaches zero.
    pub fn deinit(self: *Handlers, allocator: Allocator) void {
        self.refcnt -= 1;
        if (self.refcnt == 0) allocator.destroy(self);
    }
};

/// Per-thread signal state.
pub const State = struct {
    /// Handler table.
    ///
    /// Might be shared by threads.
    handlers: *Handlers,
    /// Pending signals not yet delivered.
    pending: Mask = 0,
    /// Currently blocked signals.
    blocked: Mask = 0,
    /// User-space address of the sigreturn trampoline page.
    trampoline: ?usize = null,
    /// Faulting address.
    fault: usize = 0,
    /// Mask to restore once the next pending signal is processed.
    saved_mask: ?Mask = null,
};

/// Deliver all pending unblocked signals to the current thread.
pub fn deliver(ctx: *Context) void {
    const th = sched.getCurrent();

    if (!isDeliverable(0, ctx)) {
        return;
    }

    // Cooperative thread-group termination checkpoint.
    if (th.group.dyingStatus()) |status| {
        task.exit(status);
    }

    while (true) {
        const deliverable = th.sigstate.pending & ~th.sigstate.blocked;
        if (deliverable == 0) break;

        const bit: u6 = @intCast(@ctz(deliverable));
        const signo: Signal = @fromBackingInt(@intCast(bit + 1));
        const action = th.sigstate.handlers.actions[bit];

        // Clear pending bit.
        th.sigstate.pending &= ~(@as(Mask, 1) << bit);

        // Restore the saved mask.
        if (th.sigstate.saved_mask) |orig| {
            th.sigstate.blocked = orig;
            th.sigstate.saved_mask = null;
        }

        // Ignore if the handler is set to ignore.
        if (action.handler == Action.sig_ignore) continue;

        // Default action if the handler is set to default.
        if (action.handler == Action.sig_default) {
            getDefaultHandler(signo)(signo);
            continue;
        }

        // Construct sigframe for user-space handler.
        setupSigFrame(
            ctx,
            th,
            @backingInt(signo),
            action,
        ) catch {
            log.err("Failed to setup sigframe for signal#{t}", .{signo});
            task.exitGroup(.{ .signal = .segv });
        };
        th.sigstate.blocked |= action.mask | (@as(Mask, 1) << bit);

        // Remaining signals delivered on next return from kernel.
        break;
    }
}

/// Restore the user context from the sigframe.
pub fn sigreturn() void {
    const ctx = sched.getCurrentCtx();
    const th = sched.getCurrent();

    urd.uaccess.allowUserAccess();
    defer urd.uaccess.disallowUserAccess();

    const mask = switch (builtin.cpu.arch) {
        .aarch64 => blk: {
            const frame: *const SigFrame = @ptrFromInt(ctx.sp_el0);

            // Restore x0–x30.
            const ctx_regs: *[31]u64 = @ptrCast(ctx);
            ctx_regs.* = frame.mcontext.regs;
            // Restore SP, PC, PSTATE.
            ctx.sp_el0 = frame.mcontext.sp;
            ctx.pc = frame.mcontext.pc;
            ctx.pstate = frame.mcontext.pstate;
            // Restore FP context.
            FpContext.restore(frame);

            break :blk frame.saved_mask;
        },

        .x86_64 => blk: {
            const frame: *const SigFrame = @ptrFromInt(ctx.rsp);
            const mc = &frame.mcontext;
            const saved_mask = frame.saved_mask;

            // Restore general-purpose registers.
            ctx.r8 = mc.r8;
            ctx.r9 = mc.r9;
            ctx.r10 = mc.r10;
            ctx.r11 = mc.r11;
            ctx.r12 = mc.r12;
            ctx.r13 = mc.r13;
            ctx.r14 = mc.r14;
            ctx.r15 = mc.r15;
            ctx.rdi = mc.rdi;
            ctx.rsi = mc.rsi;
            ctx.rbp = mc.rbp;
            ctx.rbx = mc.rbx;
            ctx.rdx = mc.rdx;
            ctx.rax = mc.rax;
            ctx.rcx = mc.rcx;
            // Restore RSP, RIP, RFLAGS.
            ctx.rsp = mc.rsp;
            ctx.rip = mc.rip;
            ctx.rflags = mc.flags;
            // Restore FP context.
            FpContext.restore(frame);

            break :blk saved_mask;
        },

        else => @compileError("Unsupported architecture."),
    };

    th.sigstate.blocked = mask;
}

/// Push a pending signal to the current thread.
pub fn push(signo: Signal) void {
    pushTo(sched.getCurrent(), signo);
}

/// Push a pending signal to the given thread.
pub fn pushTo(th: *Thread, signo: Signal) void {
    const bit: u6 = @intCast(@backingInt(signo) - 1);
    const bitmask = @as(Mask, 1) << bit;

    const ie = waiters_lock.lockDisableIrq();
    defer waiters_lock.unlockRestoreIrq(ie);

    // Set the pending bit for the signal.
    th.sigstate.pending |= bitmask;

    // Wake any thread blocked in the list waiting for this signal.
    var it = waiters.iter();
    while (it.next()) |w| {
        if (w.thread == th and w.mask & bitmask != 0) {
            _ = w.event.wake();
        }
    }
}

/// Thread descriptor blocked to wait for one of the signals.
const Waiter = struct {
    /// Thread waiting for a signal.
    thread: *Thread,
    /// Signals being waited for.
    mask: Mask,
    /// Event to wake once a matching signal becomes pending.
    event: *Event,
    /// List head.
    _head: List.Head = .{},

    const List = common.typing.InlineDoublyLinkedList(Waiter, "_head");
};

/// Lock protecting waiters list.
var waiters_lock: SpinLock = .{};
/// List of threads currently blocked waiting for a signal.
var waiters: Waiter.List = .{};

/// Block the current thread until one of the signals becomes pending.
/// Returns the signal number delivered.
///
/// Returns null if the deadline is given and no matching signal becomes pending before the deadline.
/// Otherwise, blocks indefinitely until the signals.
pub fn blocksFor(mask: Mask, deadline_ns: ?u64) ?SigInt {
    const th = sched.getCurrent();

    while (true) {
        var event: Event = .{};
        var waiter: Waiter = .{
            .thread = th,
            .mask = mask,
            .event = &event,
        };

        // Check if any matching signal is already pending.
        {
            const ie = waiters_lock.lockDisableIrq();
            defer waiters_lock.unlockRestoreIrq(ie);

            const deliverable = th.sigstate.pending & mask;
            if (deliverable != 0) {
                const bit: u6 = @intCast(@ctz(deliverable));
                th.sigstate.pending &= ~(@as(Mask, 1) << bit);
                return @as(SigInt, bit) + 1;
            }

            waiters.append(&waiter);
        }

        // Wait for a matching signal to be pushed or the deadline to expire.
        const fired = event.wait(deadline_ns);
        {
            const ie = waiters_lock.lockDisableIrq();
            defer waiters_lock.unlockRestoreIrq(ie);
            waiters.remove(&waiter);
        }

        if (!fired) return null;
    }
}

/// Block the current thread until one of the signals not in the given mask becomes pending.
///
/// The matching signal is left pending.
pub fn waitExcept(mask: Mask) void {
    const th = sched.getCurrent();
    const wanted = ~mask;

    while (true) {
        var event: Event = .{};
        var waiter: Waiter = .{
            .thread = th,
            .mask = wanted,
            .event = &event,
        };

        // Check if any matching signal is already pending.
        {
            const ie = waiters_lock.lockDisableIrq();
            defer waiters_lock.unlockRestoreIrq(ie);

            if (th.sigstate.pending & wanted != 0) return;
            waiters.append(&waiter);
        }

        // Wait for a matching signal to be pushed.
        _ = event.wait(null);
        {
            const ie = waiters_lock.lockDisableIrq();
            defer waiters_lock.unlockRestoreIrq(ie);
            waiters.remove(&waiter);
        }

        if (th.sigstate.pending & wanted != 0) return;
    }
}

/// Raise a synchronous fault signal on the current thread.
///
/// This function bypasses the signal mask
/// to ensure that the signal is always delivered to avoid infinite fault loops.
///
/// If the signal is blocked or already pending, this function immediately terminates the whole thread group.
pub fn pushSync(signo: Signal, fault: ?usize) void {
    const th = sched.getCurrent();
    const bit: u6 = @intCast(@backingInt(signo) - 1);
    const mask = @as(Mask, 1) << bit;

    if (th.sigstate.pending & mask != 0 or th.sigstate.blocked & mask != 0) {
        task.exitGroup(.{ .signal = signo });
    }

    th.sigstate.fault = if (fault) |addr| addr else 0;
    th.sigstate.blocked &= ~mask;
    th.sigstate.pending |= mask;
}

// =============================================================
// Arch-specific code
// =============================================================

const UcFlags = switch (builtin.cpu.arch) {
    .aarch64 => u64,
    .x86_64 => packed struct(u64) {
        /// Indicates the presence of extended state information.
        fp: bool = false,
        /// CS and SS field valid.
        ss: bool = false,
        /// Not used.
        _2: u62 = 0,
    },
    else => @compileError("Unsupported architecture."),
};

/// Register context saved onto the user stack when a signal is delivered.
///
/// Compatible with `ucontext_t` in the Linux ABI.
pub const SigFrame = switch (builtin.cpu.arch) {
    .aarch64 => extern struct {
        /// Context flags.
        flags: UcFlags = 0,
        /// Not used.
        link: u64 = 0,
        /// Stack information.
        stack: extern struct {
            /// Bottom of the stack.
            sp: usize,
            /// Stack flags.
            flags: i32 = 2, // disabled
            /// Size of the alternate stack region.
            size: usize = 0,
        },
        /// Signal mask.
        saved_mask: Mask = 0,
        /// Not used.
        _rsvd: [120]u8 = @splat(0),
        /// CPU context.
        mcontext: extern struct {
            /// Fault address.
            fault_addr: u64,
            /// General-purpose registers x0–x30.
            regs: [31]u64 = @splat(0),
            /// User SP.
            sp: u64,
            /// User PC at signal entry.
            pc: u64,
            /// User PSTATE.
            pstate: u64,
            /// FP/SIMD state and future expansion.
            reserved: [4096]u8 align(16) = @splat(0),
        } align(16),
    },

    .x86_64 => extern struct {
        /// Context flags.
        flags: UcFlags = .{},
        /// Not used.
        link: u64 = 0,
        /// Stack information.
        stack: extern struct {
            /// Bottom of the stack.
            sp: usize,
            /// Stack flags.
            flags: i32 = 2, // disabled
            /// Size of the alternate stack region.
            size: usize = 0,
        },
        /// CPU context.
        mcontext: extern struct {
            r8: u64,
            r9: u64,
            r10: u64,
            r11: u64,
            r12: u64,
            r13: u64,
            r14: u64,
            r15: u64,
            rdi: u64,
            rsi: u64,
            rbp: u64,
            rbx: u64,
            rdx: u64,
            rax: u64,
            rcx: u64,
            rsp: u64,
            rip: u64,
            flags: u64,
            cs: u16,
            gs: u16,
            fs: u16,
            ss: u16,
            err: u64,
            trapno: u64,
            oldmask: u64,
            cr2: u64,
            fpstate: u64 = 0, // User address of the saved FPU state.
            _reserved1: [8]u64 = @splat(0),
        },
        /// Saved signal mask.
        saved_mask: Mask,
    },

    else => @compileError("Unsupported architecture."),
};
comptime {
    urd.comptimeAssert(
        @offsetOf(SigFrame, "mcontext") == switch (builtin.cpu.arch) {
            .aarch64 => 176,
            .x86_64 => 40,
            else => unreachable,
        },
        "Invalid mcontext offset.",
        .{},
    );
    if (builtin.cpu.arch == .x86_64) {
        urd.comptimeAssert(
            @sizeOf(@FieldType(SigFrame, "mcontext")) == 256 and @offsetOf(SigFrame, "saved_mask") == 296,
            "Invalid mcontext size.",
            .{},
        );
    }
}

/// Signal information passed to a signal handler.
const SigInfo = extern struct {
    /// Signal number.
    signo: i32,
    /// Error number.
    errno: i32 = 0,
    /// Cause of the signal.
    code: i32 = 0,
    /// Reserved.
    _rsvd0: u32 = 0,
    /// Signal-specific information.
    sigfield: extern union {
        fault: extern struct {
            /// Faulting address.
            addr: usize,
            /// Padding.
            _rsvd1: [104]u8 = @splat(0),
        },
        zero: extern struct {
            _rsvd: [112]u8 = @splat(0),
        },
    } = .{ .zero = .{} },
};
comptime {
    urd.comptimeAssert(@sizeOf(SigInfo) == 128, "Invalid SigInfo size.", .{});
}

/// Stack frame pushed before delivering a signal.
const Frame = extern struct {
    /// CPU context.
    sigframe: SigFrame,
    /// Signal information.
    siginfo: SigInfo,
};

/// Size in bytes of the red-zone.
const red_zone_size: u64 = switch (builtin.cpu.arch) {
    .x86_64 => 128, // SysV
    .aarch64 => 0,
    else => @compileError("Unsupported architecture."),
};

/// Handles saving and restoring FP context in sigframe.
const FpContext = switch (builtin.cpu.arch) {
    .aarch64 => struct {
        /// Magic number.
        const fpsimd_magic = 0x46508001;

        /// Header of a record.
        const Head = extern struct {
            magic: u32,
            size: u32,
        };

        /// FP/SIMD state record.
        const FpSimd = extern struct {
            head: Head,
            fpsr: u32,
            fpcr: u32,
            vregs: [32][16]u8, // 32 128-bit vregisters.
        };

        /// Save the state into the sigframe.
        ///
        /// Returns the SP as is.
        fn save(sf: *SigFrame, sp: u64) !u64 {
            var state: arch.thread.FpuState align(16) = undefined;
            arch.thread.saveFpu(&state);

            const rec: FpSimd = .{
                .head = .{ .magic = fpsimd_magic, .size = @sizeOf(FpSimd) },
                .fpsr = state.fpsr,
                .fpcr = state.fpcr,
                .vregs = state.vregs,
            };
            @memcpy(sf.mcontext.reserved[0..@sizeOf(FpSimd)], std.mem.asBytes(&rec));

            return sp;
        }

        /// Restore the state from the sigframe.
        ///
        /// The FPU state is left untouched if there is no FP/SIMD record.
        fn restore(sf: *const SigFrame) void {
            const reserved = &sf.mcontext.reserved;
            var off: usize = 0;
            while (off + @sizeOf(Head) <= reserved.len) {
                const head = std.mem.bytesToValue(Head, reserved[off..][0..@sizeOf(Head)]);
                if (head.magic == 0 or head.size < @sizeOf(Head)) {
                    return;
                }
                if (head.size % 16 != 0) {
                    return;
                }
                if (off + head.size > reserved.len) {
                    return;
                }

                if (head.magic == fpsimd_magic and head.size >= @sizeOf(FpSimd)) {
                    const rec = std.mem.bytesToValue(FpSimd, reserved[off..][0..@sizeOf(FpSimd)]);
                    var state: arch.thread.FpuState align(16) = .{
                        .vregs = rec.vregs,
                        .fpsr = rec.fpsr,
                        .fpcr = rec.fpcr,
                    };
                    arch.thread.restoreFpu(&state);
                    return;
                }
                off += head.size;
            }
        }
    },

    .x86_64 => struct {
        /// Required alignment in bytes of the XSAVE area.
        const xarea_align = 64;
        /// Magic number indicating the XSAVE area.
        const xstate_magic1 = 0x46505853;
        /// Magic number placed after the XSAVE area.
        const xstate_magic2 = 0x46505845;
        /// Offset in the XSAVE area of the SW reserved area.
        const sw_reserved_offset = 464;

        /// SW reserved bytes in the XSAVE area.
        const SwBytes = extern struct {
            /// When set to magic1, this is an xstate context. Otherwise, legacy frame.
            magic1: u32,
            /// Total size in bytes of the fpstate area.
            extended_size: u32,
            /// Feature bit mask that's present in the memory layout.
            xfeatures: u64,
            /// Size in bytes of the XSAVE area.
            xstate_size: u32,
            ///
            _padding: [7]u32 = @splat(0),
        };

        /// Save the state onto the user stack.
        ///
        /// Returns the lowest user stack address occupied by the saved state.
        fn save(sf: *SigFrame, sp: u64) !u64 {
            // Copy to kernel buffer first.
            const size = arch.thread.getFpuStateSize();
            const total = size + @sizeOf(u32); // + for trailing magic2
            const raw = try mem.bin.alloc(u8, total + xarea_align);
            defer mem.bin.free(raw);
            const buf = raw[std.mem.alignPointerOffset(raw.ptr, xarea_align).?..][0..total];
            @memset(buf, 0);
            arch.thread.saveFpu(buf.ptr);

            // Describe the extent of the area.
            const sw: SwBytes = .{
                .magic1 = xstate_magic1,
                .extended_size = @intCast(total),
                .xfeatures = arch.thread.fpuXfeatures(),
                .xstate_size = @intCast(size),
            };
            @memcpy(buf[sw_reserved_offset..][0..@sizeOf(SwBytes)], std.mem.asBytes(&sw));
            std.mem.writeInt(u32, buf[size..][0..@sizeOf(u32)], xstate_magic2, .little);

            // Put the saved state onto the user stack.
            const uaddr = (sp - total) & ~@as(u64, xarea_align - 1);
            try urd.uaccess.copyToUser(uaddr, buf);

            // Update sigframe information.
            sf.flags.fp = true;
            sf.mcontext.fpstate = uaddr;

            return uaddr;
        }

        /// Restore the state from the sigframe.
        ///
        /// The FPU state is left untouched if the area can't be read or has an invalid header.
        fn restore(sf: *const SigFrame) void {
            // Copy from user stack into the kernel buffer first.
            const size = arch.thread.getFpuStateSize();
            const raw = mem.bin.alloc(u8, size + xarea_align) catch return;
            defer mem.bin.free(raw);
            const buf = raw[std.mem.alignPointerOffset(raw.ptr, xarea_align).?..][0..size];
            urd.uaccess.copyFromUser(buf, sf.mcontext.fpstate) catch return;

            // Validate FPU state so that restoring it always succeeds.
            if (!arch.thread.isValidFpuState(buf)) {
                return;
            }

            arch.thread.restoreFpu(buf.ptr);
        }
    },

    else => @compileError("Unsupported architecture."),
};

/// Check if signals can be delivered in the current context.
fn isDeliverable(_: SigInt, ctx: *const Context) bool {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            return ctx.sp_el0 != 0; // only deliver when returning to EL0
        },

        .x86_64 => {
            return ctx.rsp != 0; // only deliver when returning to Ring-3.
        },

        else => @compileError("Unsupported architecture."),
    }
}

// =============================================================
// Internals
// =============================================================

/// Setup sigframe and modify the user context to execute the signal handler.
fn setupSigFrame(ctx: *Context, th: *Thread, signo: SigInt, action: Action) !void {
    const trampoline = if (th.sigstate.trampoline) |addr|
        addr
    else
        try allocateTrampoline(th);

    switch (builtin.cpu.arch) {
        .aarch64 => {
            var local: Frame = std.mem.zeroes(Frame);

            // Save user context into the sigframe.
            const regs: *const [31]u64 = @ptrCast(ctx);
            const sf = &local.sigframe;
            {
                sf.saved_mask = th.sigstate.blocked;
                sf.mcontext = .{
                    .fault_addr = th.sigstate.fault,
                    .regs = regs.*,
                    .sp = ctx.sp_el0,
                    .pc = ctx.pc,
                    .pstate = ctx.pstate,
                };
            }

            // Push signal information.
            const si = &local.siginfo;
            {
                si.signo = @intCast(signo);
                si.sigfield = switch (@as(Signal, @fromBackingInt(@intCast(signo)))) {
                    .segv => .{ .fault = .{
                        .addr = th.sigstate.fault,
                    } },
                    else => .{ .zero = .{} },
                };
            }

            // Push the FP state skipping red-zone.
            const fp_sp = try FpContext.save(sf, ctx.sp_el0 - red_zone_size);
            const frame_uaddr = (fp_sp - @sizeOf(Frame)) & ~@as(u64, 0xF);

            // Copy constructed sigframe and siginfo to user space.
            try urd.uaccess.copyToUser(frame_uaddr, std.mem.asBytes(&local));

            // Modify user context to execute the signal handler.
            ctx.x0 = signo;
            ctx.x1 = frame_uaddr + @offsetOf(Frame, "siginfo");
            ctx.x2 = frame_uaddr + @offsetOf(Frame, "sigframe");
            ctx.pc = action.handler;
            ctx.sp_el0 = frame_uaddr;
            ctx.x30 = trampoline;
        },

        .x86_64 => {
            var local: Frame = std.mem.zeroes(Frame);

            // Save user context into the sigframe.
            const sf = &local.sigframe;
            {
                sf.saved_mask = th.sigstate.blocked;
                sf.mcontext = .{
                    .r8 = ctx.r8,
                    .r9 = ctx.r9,
                    .r10 = ctx.r10,
                    .r11 = ctx.r11,
                    .r12 = ctx.r12,
                    .r13 = ctx.r13,
                    .r14 = ctx.r14,
                    .r15 = ctx.r15,
                    .rdi = ctx.rdi,
                    .rsi = ctx.rsi,
                    .rbp = ctx.rbp,
                    .rbx = ctx.rbx,
                    .rdx = ctx.rdx,
                    .rax = ctx.rax,
                    .rcx = ctx.rcx,
                    .rsp = ctx.rsp,
                    .rip = ctx.rip,
                    .flags = ctx.rflags,
                    .cs = @truncate(ctx.cs),
                    .gs = 0, // TODO
                    .fs = 0, // TODO
                    .ss = @truncate(ctx.ss),
                    .err = 0, // TODO
                    .trapno = 0, // TODO
                    .oldmask = 0, // TODO
                    .cr2 = th.sigstate.fault,
                };
            }

            // Push signal information.
            const si = &local.siginfo;
            {
                si.signo = @intCast(signo);
                si.sigfield = switch (@as(Signal, @fromBackingInt(@intCast(signo)))) {
                    .segv => .{ .fault = .{
                        .addr = th.sigstate.fault,
                    } },
                    else => .{ .zero = .{} },
                };
            }

            // Push the FP state skipping red-zone.
            const fp_sp = try FpContext.save(sf, ctx.rsp - red_zone_size);
            const frame_uaddr = (fp_sp - @sizeOf(Frame)) & ~@as(u64, 0xF);
            // Copy constructed sigframe to user space.
            try urd.uaccess.copyToUser(frame_uaddr, std.mem.asBytes(&local));

            // Push the trampoline address as the return address for the handler.
            const ret_uaddr = frame_uaddr - @sizeOf(u64);
            try urd.uaccess.putUser(u64, ret_uaddr, trampoline);

            // Modify user context to execute the signal handler.
            ctx.rdi = signo;
            ctx.rsi = frame_uaddr + @offsetOf(Frame, "siginfo");
            ctx.rdx = frame_uaddr + @offsetOf(Frame, "sigframe");
            ctx.rip = action.handler;
            ctx.rsp = ret_uaddr;
        },

        else => @compileError("Unsupported architecture."),
    }
}

/// Allocate a per-thread trampoline page.
fn allocateTrampoline(th: *Thread) !usize {
    // Map as user-RWX kernel-RWX.
    const uva = try th.vmm.mapAnon(mem.page_size, .{
        .ur = true,
        .uw = true,
        .ux = true,
        .kr = true,
        .kw = true,
        .kx = true,
    });

    // Place the trampoline code.
    const tramp = generateTrampoline();
    const src: [*]const u8 = @ptrFromInt(@intFromPtr(tramp.code));
    try urd.uaccess.copyToUser(uva, src[0..tramp.size]);

    // Remap as user-RX kernel-RX.
    try th.vmm.remap(uva, mem.page_size, .{
        .ur = true,
        .uw = false,
        .ux = true,
        .kr = true,
        .kw = false,
        .kx = true,
    });

    th.sigstate.trampoline = uva;
    return uva;
}

const Trampoline = struct {
    /// Trampoline code.
    code: *const fn () callconv(.naked) noreturn,
    /// Size in bytes of the trampoline code.
    size: usize,
};

/// Generate architecture-specific trampoline code for signal handlers.
fn generateTrampoline() Trampoline {
    return switch (builtin.cpu.arch) {
        .aarch64 => .{
            .size = 8,
            .code = struct {
                fn f() callconv(.naked) noreturn {
                    asm volatile (
                        \\movz x8, #139 // rt_sigreturn
                        \\svc  #0
                    );
                }
            }.f,
        },

        .x86_64 => .{
            .size = 7,
            .code = struct {
                fn f() callconv(.naked) noreturn {
                    asm volatile (
                        \\movl $15, %eax // rt_sigreturn
                        \\syscall
                    );
                }
            }.f,
        },

        else => @compileError("Unsupported architecture."),
    };
}

// =============================================================
// Default handlers
// =============================================================

/// Get a default handler for the given signal number.
fn getDefaultHandler(signo: Signal) *const fn (Signal) void {
    return switch (signo) {
        .child => defaultIgnore,
        else => defaultAbort,
    };
}

/// Default signal handler to abort.
fn defaultAbort(signo: Signal) void {
    task.exitGroup(.{ .signal = signo });
}

/// Default signal handler that does nothing.
fn defaultIgnore(_: Signal) void {}

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.signal);
const common = @import("common");
const arch = @import("arch").impl;
const Context = arch.exception.Context;
const urd = @import("urthr");
const mem = urd.mem;
const sched = urd.sched;
const task = urd.task;
const Thread = task.thread.Thread;
const SpinLock = urd.sync.SpinLock;
const Event = urd.sync.Event;
