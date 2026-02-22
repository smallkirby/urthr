/// Fixed-capacity single-producer single-consumer packet queue.
///
/// `max_packet_size` is the maximum frame size in bytes that can be stored in each slot.
pub fn PacketQueue(comptime max_packet_size: comptime_int) type {
    return struct {
        const Self = @This();

        /// Maximum number of packets in the queue.
        const capacity = 64;

        /// Descriptor returned to the consumer when dequeuing a packet.
        ///
        /// Caller must call `release()` after processing to free the slot.
        /// Caller must NOT directly free the data buffer.
        pub const Descriptor = struct {
            // Slice referencing the packet data.
            data: []const u8,
            // Index of the slot in the ring buffer.
            _index: usize,
        };

        // Fat pointer to the packet data.
        const Packet = struct {
            /// Buffer for packet data.
            ///
            /// The length of valid data is indicated by the `len` field.
            data: [max_packet_size]u8 = undefined,
            /// Actual length of the packet data stored in the buffer.
            len: u16 = 0,
        };

        /// Ring buffer of packets.
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

        /// Acquire a writable slot for the producer.
        ///
        /// Returns a writable buffer if space is available.
        /// If the queue is full, increments the drop counter and returns null.
        pub fn acquireSlot(self: *Self) ?[]u8 {
            self.lock.lock();
            defer self.lock.unlock();

            if (self.count >= capacity) {
                self.drops += 1;
                return null;
            }

            return &self.slots[self.head].data;
        }

        /// Commit a previously acquired slot with the actual data length.
        ///
        /// Sets the packet length, advances the head pointer, increments
        /// the count, and wakes the consumer thread.
        pub fn commitSlot(self: *Self, len: u16) void {
            self.slots[self.head].len = len;

            self.lock.lock();

            self.head = (self.head + 1) % capacity;
            self.count += 1;
            _ = self.waitq.wake();

            self.lock.unlock();
        }

        /// Dequeue a packet in thread context.
        ///
        /// Blocks if the queue is empty until a packet is available.
        /// Returns a Descriptor holding a direct reference to the ring buffer slot.
        ///
        /// The caller must call `release()` after processing to return the ownership of the slot.
        pub fn dequeue(self: *Self) Descriptor {
            const ie = self.lock.lockDisableIrq();
            defer self.lock.unlockRestoreIrq(ie);

            while (self.count == 0) {
                self.waitq.wait(&self.lock);
            }

            const slot = &self.slots[self.tail];
            const desc = Descriptor{
                .data = slot.data[0..slot.len],
                ._index = self.tail,
            };

            return desc;
        }

        /// Release a previously dequeued slot.
        ///
        /// Advances the tail pointer and decrements the count,
        /// making the slot available for reuse by the producer.
        pub fn release(self: *Self, desc: Descriptor) void {
            const ie = self.lock.lockDisableIrq();
            defer self.lock.unlockRestoreIrq(ie);

            rtt.expect(desc._index == self.tail);
            self.tail = (self.tail + 1) % capacity;
            self.count -= 1;
        }
    };
}

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const SpinLock = urd.SpinLock;
const WaitQueue = urd.WaitQueue;
