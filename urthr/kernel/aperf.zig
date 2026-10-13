//! Arbitrary performance trace event recorder.

var heap: std.heap.FixedBufferAllocator = undefined;
var map: std.StringHashMap(AperfRecord) = undefined;
var lock: sync.SpinLock = .{};

var initialized: bool = false;

const heap_size = 4096 * 16;

/// Initialize the arbitrary performance tracer subsystem.
///
/// TODO: enable only when specified by build options.
pub fn init(allocator: Allocator) Allocator.Error!void {
    const buffer = try allocator.alloc(u8, heap_size);
    heap = .init(buffer);
    map = .init(heap.allocator());
    initialized = true;
}

/// Begin recording an arbitrary performance trace event with the given name.
pub fn begin(comptime name: []const u8) AperfHandle {
    if (!initialized) {
        return .empty;
    }

    return .{
        .name = name,
        .start = urd.time.getCurrentTimestamp(),
    };
}

const AperfHandle = struct {
    /// Comptime name of the event.
    name: []const u8,
    /// Timestamp when the event recording started.
    start: u64,
    /// Indicates whether the handle is valid.
    valid: bool = true,

    pub const empty = AperfHandle{
        .name = undefined,
        .start = 0,
        .valid = false,
    };

    pub fn end(self: AperfHandle) void {
        if (self.valid == false) {
            return;
        }

        const now = urd.time.getCurrentTimestamp();
        const duration = now - self.start;

        // Costly operation follows.

        const ie = lock.lockDisableIrq();
        defer lock.unlockRestoreIrq(ie);

        if (map.getPtr(self.name)) |rec| {
            rec.count += 1;
            rec.ns += duration;
        } else {
            map.put(self.name, .{
                .name = self.name,
                .count = 1,
                .ns = duration,
            }) catch @panic("Failed to insert performance record");
        }
    }
};

const AperfRecord = struct {
    /// Comptime name of the event.
    name: []const u8,
    /// Number of occurrences of the event.
    count: u64,
    /// Total time spent in the event in nanoseconds.
    ns: u128,
};

// =============================================================
// syscall
// =============================================================

/// Fetch all recorded arbitrary performance events.
///
/// Fetched items are written into the user buffer and cleared from the records.
/// When `buf` is too small to hold all records, this returns error and all records are not cleared.
pub fn sysAperf(buf: [*]u8, len: usize) syscall.ReturnType {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    var ptr: [*]u8 = buf;
    var total: u64 = 0;
    var iter = map.valueIterator();
    while (iter.next()) |entry| {
        const rec = common.perf.AperfRecord{
            .name_size = entry.name.len,
            .count = entry.count,
            .ns = entry.ns,
        };
        const size = @sizeOf(common.perf.AperfRecord) + entry.name.len;
        if (size > len - total) {
            return .err(.inval);
        }

        uaccess.copyToUser(ptr, std.mem.asBytes(&rec)) catch {
            return .err(.fault);
        };
        ptr += @sizeOf(common.perf.AperfRecord);
        uaccess.copyToUser(ptr, entry.name) catch {
            return .err(.fault);
        };
        ptr += entry.name.len;

        total += size;
    }

    map.clearRetainingCapacity();

    return .success(@intCast(total));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const urd = @import("urthr");
const sync = urd.sync;
const syscall = urd.syscall;
const uaccess = urd.uaccess;
