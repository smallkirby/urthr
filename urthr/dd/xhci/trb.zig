/// Type-erased TRB.
pub const Trb = packed struct(u128) {
    /// Parameter. Ring-specific.
    parameter: u64,
    /// Status. Ring-specific.
    status: u32,
    /// Cycle bit.
    cycle: u1,
    /// Evaluate Next TRB.
    ent: u1,
    /// Ring-specific field.
    _ring_specific: u8,
    /// Type of TRB.
    type: TrbType,
    /// Control. Ring-specific.
    control: u16,
};

/// Type of TRB.
pub const TrbType = enum(u6) {
    /// Normal TRB.
    normal = 1,
    /// Setup Stage TRB.
    setup = 2,
    /// Data Stage TRB.
    data = 3,
    /// Status Stage TRB.
    status = 4,
    /// Link TRB.
    link = 6,
    /// No Op TRB.
    noop = 8,
    /// Enable Slot Command TRB.
    enable_slot = 9,
    /// Address Device Command TRB.
    address_device = 11,
    /// Configure Endpoint Command TRB.
    configure_endpoint = 12,
    /// Transfer Event.
    transfer_event = 32,
    /// Command Completion Event TRB.
    command_completion = 33,
    /// Port Status Change Event TRB.
    port_status_change = 34,

    _,
};

/// Transfer direction.
pub const Direction = enum(u1) {
    out = 0,
    in = 1,
};

/// TRB completion codes.
pub const ErrorCode = enum(u8) {
    invalid = 0,
    success = 1,
    data_buffer_error = 2,
    babble_detected = 3,
    transaction_error = 4,
    trb_error = 5,
    stall_error = 6,
    resource_error = 7,
    bandwidth_error = 8,
    no_slots_available = 9,
    invalid_stream = 10,
    slot_not_enabled = 11,
    endpoint_not_enabled = 12,
    short_packet = 13,
    ring_underrun = 14,
    ring_overrun = 15,
    vf_event_ring_full = 16,
    parameter_error = 17,
    bandwidth_overrun = 18,
    context_state_error = 19,
    no_ping_response = 20,
    event_ring_full = 21,
    incompatible_device = 22,
    missed_service = 23,
    command_ring_stop = 24,
    command_aborted = 25,
    stopped = 26,
    stopped_length_invalid = 27,
    stopped_short_packet = 28,
    max_exit_latency = 29,
    _reserved1 = 30,
    isoch_buffer_overrun = 31,
    event_lost = 32,
    undefined_error = 33,
    invalid_stream_id = 34,
    secondary_bandwidth_error = 35,
    split_transaction_error = 36,

    _,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const mem = urd.mem;
const Phys = mem.Phys;
