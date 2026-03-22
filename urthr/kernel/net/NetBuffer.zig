const Self = @This();

/// Headroom reserved for protocol headers.
///
/// The value is chosen to be large enough for common protocol stacks,
/// but it's better to be reworked to support dynamic headroom.
pub const size_default_headroom: usize = 64;

/// Underlying contiguous buffer.
_buffer: []u8,
/// Offset of the start of valid data within the buffer.
_head: usize,
/// Offset of the end of valid data within the buffer.
_tail: usize,
/// Allocator used for deallocation.
_allocator: Allocator,

/// Allocate a new NetBuffer with max_headroom and the given data capacity.
pub fn init(data_size: usize, allocator: Allocator) Allocator.Error!Self {
    const buffer = try allocator.alloc(u8, size_default_headroom + data_size);
    return .{
        ._buffer = buffer,
        ._head = size_default_headroom,
        ._tail = size_default_headroom,
        ._allocator = allocator,
    };
}

/// Free the underlying buffer.
pub fn deinit(self: *Self) void {
    self._allocator.free(self._buffer);
}

/// Prepend bytes in the headroom.
///
/// Returns a writable slice for the caller to fill.
pub fn prepend(self: *Self, n: usize) net.Error![]u8 {
    if (self._head < n) return net.Error.OutOfMemory;

    self._head -= n;

    return self._buffer[self._head .. self._head + n];
}

/// Append bytes at the tail.
///
/// Returns a writable slice for the caller to fill.
pub fn append(self: *Self, n: usize) net.Error![]u8 {
    if (self._tail + n > self._buffer.len) return net.Error.OutOfMemory;

    const start = self._tail;
    self._tail += n;

    return self._buffer[start..self._tail];
}

/// Strip bytes from the front and return the consumed slice.
pub fn consume(self: *Self, n: usize) net.Error![]const u8 {
    if (self._tail - self._head < n) return net.Error.NoData;

    const start = self._head;
    self._head += n;

    return self._buffer[start .. start + n];
}

/// Return the current valid data slice.
pub fn data(self: *const Self) []const u8 {
    return self._buffer[self._head..self._tail];
}

/// Return the current data length in bytes.
pub fn len(self: *const Self) usize {
    return self._tail - self._head;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const net = @import("urthr").net;
