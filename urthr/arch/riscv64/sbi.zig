//! RISC-V Supervisor Binary Interface client implementation.
//!
//! ref. RISC-V Supervisor Binary Interface Specification Version v3.0, 2025-07-16: Ratified

pub const Error = error{
    /// Failed.
    Failed,
    /// Not supported.
    NotSupported,
    /// Invalid parameters.
    InvalidParam,
    /// Denied or not allowed.
    Denied,
    /// Invalid address.
    InvalidAddress,
    /// Already available.
    AlreadyAvailable,
    /// Already started.
    AlreadyStarted,
    /// Already stopped.
    AlreadyStopped,
    /// Shared memory not available.
    NoShmem,
    /// Invalid state.
    InvalidState,
    /// Bad or invalid range.
    BadRange,
    /// Failed due to timeout.
    Timeout,
    /// I/O error.
    Io,
    /// Denied or not allowed due to lock status.
    DeniedLocked,
};

/// SBI error codes.
const ErrorCode = enum(isize) {
    /// Completed successfully.
    success = 0,
    /// Failed.
    failed = -1,
    /// Not supported.
    not_supported = -2,
    /// Invalid parameters.
    invalid_param = -3,
    /// Denied or not allowed.
    denied = -4,
    /// Invalid address.
    invalid_address = -5,
    /// Already available.
    already_available = -6,
    /// Already started.
    already_started = -7,
    /// Already stopped.
    already_stopped = -8,
    /// Shared memory not available.
    no_shmem = -9,
    /// Invalid state.
    invalid_state = -10,
    /// Bad or invalid range.
    bad_range = -11,
    /// Failed due to timeout.
    timeout = -12,
    /// I/O error.
    io = -13,
    /// Denied or not allowed due to lock status.
    denied_locked = -14,
};

/// Return value of an SBI call.
const RetValue = struct {
    /// Error code.
    ec: ErrorCode,
    /// Data value.
    value: usize,

    pub fn unwrap(self: RetValue) Error!usize {
        switch (self.ec) {
            .success => return self.value,
            .failed => return Error.Failed,
            .not_supported => return Error.NotSupported,
            .invalid_param => return Error.InvalidParam,
            .denied => return Error.Denied,
            .invalid_address => return Error.InvalidAddress,
            .already_available => return Error.AlreadyAvailable,
            .already_started => return Error.AlreadyStarted,
            .already_stopped => return Error.AlreadyStopped,
            .no_shmem => return Error.NoShmem,
            .invalid_state => return Error.InvalidState,
            .bad_range => return Error.BadRange,
            .timeout => return Error.Timeout,
            .io => return Error.Io,
            .denied_locked => return Error.DeniedLocked,
        }
    }
};

/// SBI extension IDs.
pub const Eid = enum(usize) {
    /// Base extension.
    base = 0x0000_0010,
    /// Timer extension.
    timer = 0x54494D45,
    /// Hart State Management extension.
    hsm = 0x48534D,
    /// IPI extension.
    ipi = 0x00735049,
};

/// SBI function IDs.
fn Fid(comptime eid: Eid) type {
    return switch (eid) {
        .base => enum(usize) {
            /// Get SBI specification version.
            get_spec_version = 0x00,
            /// Get SBI implementation ID.
            get_impl_id = 0x01,
            /// Get SBI implementation version.
            get_impl_version = 0x02,
            /// Probe SBI extension.
            sbi_probe_extension = 0x03,
            /// Get machine vendor ID.
            get_mvendorid = 0x04,
            /// Get machine architecture ID.
            get_marchid = 0x05,
            /// Get machine implementation ID.
            get_mimpid = 0x06,
        },

        .timer => enum(usize) {
            /// Set timer.
            set_timer = 0x00,
        },

        .hsm => enum(usize) {
            /// Hart start.
            hart_start = 0x00,
            /// Hart stop.
            hart_stop = 0x01,
            /// Hart get status.
            hart_get_status = 0x02,
        },

        .ipi => enum(usize) {
            /// Send IPI.
            send_ipi = 0x00,
        },
    };
}

// =============================================================
// Base extension

pub const SpecVersion = packed struct(u32) {
    /// Minor version.
    minor: u24,
    /// Major version.
    major: u8,
};

/// Get the current specification version.
pub fn getSpecVersion() Error!SpecVersion {
    const value = try call(.base, .get_spec_version, 0, 0, 0).unwrap();
    return @bitCast(@as(u32, @truncate(value)));
}

/// Get SBI implementation ID.
pub fn getImplId() Error!usize {
    return call(.base, .get_impl_id, 0, 0, 0).unwrap();
}

/// Get SBI implementation version.
pub fn getImplVersion() Error!usize {
    return call(.base, .get_impl_version, 0, 0, 0).unwrap();
}

/// Check if the given EID is available.
pub fn probeExtension(eid: Eid) Error!bool {
    const ret = try call(.base, .sbi_probe_extension, eid, 0, 0).unwrap();
    return ret != 0;
}

/// Get a value that is legal for the mvendorid CSR.
pub fn getMvendorId() Error!usize {
    return call(.base, .get_mvendorid, 0, 0, 0).unwrap();
}

/// Get a value that is legal for the marchid CSR.
pub fn getMarchId() Error!usize {
    return call(.base, .get_marchid, 0, 0, 0).unwrap();
}

/// Get a value that is legal for the mimpid CSR.
pub fn getMimpId() Error!usize {
    return call(.base, .get_mimpid, 0, 0, 0).unwrap();
}

// =============================================================
// Timer extension

/// Programs the clock for the next event after the given absolute time.
pub fn setTimer(time: usize) Error!void {
    _ = try call(.timer, .set_timer, time, 0, 0).unwrap();
}

// =============================================================
// Hart State Management extension

/// Hart states.
pub const HartState = enum(usize) {
    /// The hart is physically powered-up and executing normally.
    started = 0,
    /// The hart is not executing in S-mode or any lower privilege mode.
    stopped = 1,
    /// Some other hart has requested to start the hart from the STOPPED state.
    start_pending = 2,
    /// The hart has requested to stop itself from the STARTED state.
    stop_pending = 3,
    /// The hart is in a platform specific suspended state.
    suspended = 4,
    /// The hart has requested to put itself in a platform specific low power state.
    suspend_pending = 5,
    /// An interrupt or platform specific HW event has caused the hart to resume normal execution.
    resume_pending = 6,
};

/// Request to start executing the target hart in S-mode at the given address.
///
/// Register state:
/// - satp          : 0
/// - sstatus.SIE   : 0
/// - a0            : hart ID
/// - a1            : opaque parameter
///
/// This call is asynchronous and may return before the target hart starts executing.
pub fn hartStart(hartid: usize, start_addr: usize, parameter: usize) Error!void {
    _ = try call(.hsm, .hart_start, hartid, start_addr, parameter).unwrap();
}

/// Requests to stop executing the calling hart in S-mode.
///
/// Must be called with S-mode IRQ disabled.
pub fn hartStop(hartid: usize) Error!noreturn {
    _ = try call(.hsm, .hart_stop, hartid, 0, 0).unwrap();

    unreachable;
}

/// Get the hart state.
pub fn hartState(hartid: usize) Error!HartState {
    const ret = call(.hsm, .hart_state, hartid, 0, 0).unwrap();
    return @fromBackingInt(ret.value);
}

// =============================================================
// IPI extension

/// Send an IPI to all the harts defined in the mask.
pub fn sendIpi(hart_mask: usize, hart_mask_base: usize) Error!void {
    _ = try call(.ipi, .send_ipi, hart_mask, hart_mask_base, 0).unwrap();
}

// =============================================================
// Internals
// =============================================================

/// Make an SBI call.
fn call(comptime eid: Eid, fid: Fid(eid), a0: anytype, a1: anytype, a2: anytype) RetValue {
    var err: isize = undefined;
    var value: usize = undefined;
    asm volatile (
        \\ecall
        : [err] "={a0}" (err),
          [value] "={a1}" (value),
        : [eid] "{a7}" (eid),
          [fid] "{a6}" (fid),
          [a0] "{a0}" (a0),
          [a1] "{a1}" (a1),
          [a2] "{a2}" (a2),
        : .{ .memory = true });
    return .{
        .ec = @fromBackingInt(@intCast(err)),
        .value = value,
    };
}
