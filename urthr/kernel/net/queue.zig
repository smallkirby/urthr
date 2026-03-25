pub const Error = error{
    /// Queue is full.
    Full,
};

/// Fixed-capacity single-producer single-consumer receive queue.
///
/// Stores references to externally-owned packet data waiting to be processed by the consumer thread.
pub const RxQueue = struct {
    const Self = @This();

    /// Maximum number of packets in the queue.
    const capacity = 64;

    /// Packet slot holding a reference to externally-owned data.
    pub const Packet = struct {
        /// Slice referencing the packet data.
        data: []const u8 = undefined,
        /// Network device associated with the packet.
        device: *Device = undefined,
        /// Driver-specific RX buffer handle for deferred release.
        handle: usize = 0,
    };

    /// Ring buffer of packet slots.
    slots: [capacity]Packet = @splat(Packet{}),
    /// Write index (producer).
    head: usize = 0,
    /// Read index (consumer).
    tail: usize = 0,
    /// Number of packets currently in the queue.
    count: usize = 0,
    /// Protecting lock.
    lock: SpinLock = .{},
    /// Wait queue for the consumer thread.
    waitq: WaitQueue = .{},
    /// Number of dropped packets due to queue full.
    drops: u64 = 0,

    /// Enqueue a packet into the queue.
    ///
    /// Enqueue a packet and wake the consumer thread.
    /// If the queue is full, the packet is dropped and the underlying buffer is returned to the device immediately.
    pub fn enqueue(self: *Self, pkt: Packet) Error!void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.count >= capacity) {
            self.drops += 1;
            pkt.device.releaseRxBuf(pkt.handle);
            return Error.Full;
        }

        self.slots[self.head] = pkt;
        self.head = (self.head + 1) % capacity;
        self.count += 1;

        _ = self.waitq.wake();
    }

    /// Dequeue a packet in thread context.
    ///
    /// Blocks if the queue is empty until a packet is available.
    /// Returns a pointer to the Packet slot.
    ///
    /// The caller must call `release()` after processing to return the ownership of the slot.
    pub fn dequeue(self: *Self) *const Packet {
        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);

        while (self.count == 0) {
            self.waitq.wait(&self.lock);
        }

        return &self.slots[self.tail];
    }

    /// Release a previously dequeued slot.
    ///
    /// Returns the underlying buffer to the device
    /// and then frees the slot for reuse by the producer.
    pub fn release(self: *Self, pkt: *const Packet) void {
        pkt.device.releaseRxBuf(pkt.handle);

        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);

        rtt.expectEqual(pkt, &self.slots[self.tail]);
        self.tail = (self.tail + 1) % capacity;
        self.count -= 1;
    }
};

/// Fixed-capacity single-producer single-consumer transmit queue.
///
/// Stores owned packet data waiting to be transmitted by the TX worker thread.
pub const TxQueue = struct {
    const Self = @This();

    /// Maximum number of packets in the queue.
    const capacity = 64;

    /// Packet slot holding owned transmit data.
    pub const TxPacket = struct {
        /// Network device to transmit on.
        device: *Device,
        /// Destination hardware address,
        dest: [Device.max_addr_len]u8,
        /// Length of the destination hardware address.
        dest_len: u8,
        /// Protocol type.
        protocol: Protocol,
        /// Packet data owned by this slot.
        buf: NetBuffer,
    };

    /// Ring buffer of packet slots.
    slots: [capacity]TxPacket = undefined,
    /// Write index (producer).
    head: usize = 0,
    /// Read index (consumer).
    tail: usize = 0,
    /// Number of packets currently in the queue.
    count: usize = 0,
    /// Protecting lock.
    lock: SpinLock = .{},
    /// Wait queue for the TX worker thread.
    waitq: WaitQueue = .{},
    /// Number of dropped packets due to queue full.
    drops: u64 = 0,

    /// Enqueue a TX packet.
    ///
    /// Takes ownership of `pkt.buf` on success.
    /// If the queue is full, returns `error.Full` without touching `pkt.buf`.
    /// The caller is responsible for freeing `pkt.buf` on failure.
    pub fn enqueue(self: *Self, pkt: TxPacket) Error!void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.count >= capacity) {
            self.drops += 1;
            return Error.Full;
        }

        self.slots[self.head] = pkt;
        self.head = (self.head + 1) % capacity;
        self.count += 1;

        _ = self.waitq.wake();
    }

    /// Dequeue a TX packet in thread context.
    ///
    /// Blocks if the queue is empty until a packet is available.
    /// Returns the `TxPacket` by value; the caller takes ownership of the `buf`.
    pub fn dequeue(self: *Self) TxPacket {
        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);

        while (self.count == 0) {
            self.waitq.wait(&self.lock);
        }

        const pkt = self.slots[self.tail];
        self.tail = (self.tail + 1) % capacity;
        self.count -= 1;

        return pkt;
    }
};

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const SpinLock = urd.SpinLock;
const WaitQueue = urd.WaitQueue;
const Device = @import("Device.zig");
const NetBuffer = @import("NetBuffer.zig");
const Protocol = urd.net.Protocol;
