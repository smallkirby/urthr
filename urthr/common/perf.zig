//! Wire format for kernel performance trace events.

// =============================================================
// Structured performance trace events
// =============================================================

/// Kind of a recorded event.
pub const Event = enum(u8) {
    /// Entered a syscall.
    syscall_enter,
    /// Exited a syscall.
    syscall_exit,
    /// A thread was switched into the CPU.
    sched_switch,
    /// The call stack when the CPU was sampled.
    stack_sample,
};

/// Syscall Enter event payload.
pub const SyscallEnter = extern struct {
    /// Syscall number.
    nr: u64,
};

/// Syscall Exit event payload.
pub const SyscallExit = extern struct {
    /// Syscall number.
    nr: u64,
};

/// Fixed-size thread name.
pub const ThreadName = extern struct {
    /// Maximum length of a thread name.
    pub const max_len = 32;

    /// Zero-padded name.
    bytes: [max_len]u8,

    /// Create a thread name, truncating it if too long.
    pub fn init(name: []const u8) ThreadName {
        var self: ThreadName = .{ .bytes = @splat(0) };
        const n = @min(name.len, max_len);
        @memcpy(self.bytes[0..n], name[0..n]);
        return self;
    }

    /// Get the name without the padding.
    pub fn slice(self: *const ThreadName) []const u8 {
        var len: usize = 0;
        while (len < max_len and self.bytes[len] != 0) : (len += 1) {}
        return self.bytes[0..len];
    }
};

/// Scheduler Switch event payload.
pub const SchedSwitch = extern struct {
    /// Name of the thread switched in.
    name: ThreadName,
};

/// Stack Sample event payload.
pub const StackSample = extern struct {
    /// Maximum number of frames in a sample.
    pub const max_depth = 12;

    /// Number of valid entries in `frames`.
    depth: u32,
    /// Attributes of the sample.
    flags: Flags,
    /// Call stack.
    ///
    /// The first element is the PC of the interrupted code, and the others are return addresses.
    frames: [max_depth]u64,

    pub const Flags = packed struct(u32) {
        /// The CPU was executing in user mode when sampled.
        ///
        /// The kernel call stack is not available in that case.
        user: bool = false,
        /// Not used.
        _1: u31 = 0,
    };
};

/// Event-specific payload.
pub const EventPayload = extern struct {
    /// Kind of event.
    tag: Event,
    /// Event payload.
    data: extern union {
        syscall_enter: SyscallEnter,
        syscall_exit: SyscallExit,
        sched_switch: SchedSwitch,
        stack_sample: StackSample,
    },

    /// Type of the data associated with the given event tag.
    fn DataOf(comptime tag: Event) type {
        return @FieldType(@FieldType(EventPayload, "data"), @tagName(tag));
    }

    /// Build a payload from its corresponding data value.
    pub fn init(comptime tag: Event, value: DataOf(tag)) EventPayload {
        return .{
            .tag = tag,
            .data = @unionInit(
                @FieldType(EventPayload, "data"),
                @tagName(tag),
                value,
            ),
        };
    }

    /// Kind of event this payload belongs to.
    pub fn event(self: EventPayload) Event {
        return self.tag;
    }
};

/// A single recorded event.
pub const Record = extern struct {
    /// Timestamp in nanoseconds since boot.
    timestamp_ns: u64,
    /// ID of the thread.
    tid: u32,
    /// Logical ID of the core.
    core: u32,
    /// Event-specific payload.
    payload: EventPayload,
};

// =============================================================
// Arbitrary performance trace events
// =============================================================

/// Performance record for arbitrary events.
pub const AperfRecord = extern struct {
    /// Size in bytes of the event name.
    name_size: u64 align(1),
    /// Number of occurrences of the event.
    count: u64 align(1),
    /// Total time spent in the event in nanoseconds.
    ns: u128 align(1),
    /// Event name stored inline after this struct.
    __name: void align(1) = {},
};
