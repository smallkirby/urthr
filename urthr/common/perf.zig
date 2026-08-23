//! Wire format for kernel performance trace events.

/// Kind of a recorded event.
pub const Event = enum(u8) {
    /// Entered a syscall.
    syscall_enter,
    /// Exited a syscall.
    syscall_exit,
    /// A thread was assigned the given name.
    thread_name,
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

/// Thread Name event payload.
pub const ThreadName = extern struct {
    /// Maximum length of a thread name.
    pub const max_len = 32;

    /// Thread name.
    name: [max_len]u8,
};

/// Event-specific payload.
pub const EventPayload = extern struct {
    /// Kind of event.
    tag: Event,
    /// Event payload.
    data: extern union {
        syscall_enter: SyscallEnter,
        syscall_exit: SyscallExit,
        thread_name: ThreadName,
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
