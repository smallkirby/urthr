//! Buddy Allocator singleton.
//!
//! Implements `PageAllocator` interface.

pub const Error = PageAllocator.Error;

/// Spin lock for this allocator.
var lock: SpinLock = .{};
/// Arena.
var arena: Arena = undefined;

/// Vtable for PageAllocator interface.
const vtable = PageAllocator.Vtable{
    .allocPages = allocPages,
    .freePages = freePages,
    .virt2phys = virt2physInterface,
    .phys2virt = phys2virtInterface,
};

/// Exponent of power of 2 representing the number of contiguous physical pages.
const SizeOrder = u8;
/// Physical address type.
const Phys = usize;
/// Virtual address type.
const Virt = usize;

/// Page size in bytes.
const page_size = 4 * units.kib;
//// Page size shift.
const page_shift = 12;
/// Page size mask.
const page_mask = page_size - 1;

/// PageAllocator interface.
pub const interface = PageAllocator{
    .ptr = &.{},
    .vtable = &vtable,
};

/// Initialize buddy allocator.
///
/// - `avail`     : Memory region that the allocator can use.
/// - `reserveds` : List of reserved regions that the allocator must not use.
///
/// `reserveds` may be not sorted, but must not overlap each other.
///
/// All arguments are in physical addresses.
pub fn init(avails: []const Range, reserveds: []Range, comptime log_fn: ?urd.LogFn) void {
    rtt.expect(avails.len > 0);

    // Sort `reserveds` by the starting address.
    {
        const sort_fn = struct {
            fn lt(_: void, lhs: Range, rhs: Range) bool {
                return lhs.start < rhs.start;
            }
        }.lt;
        std.mem.sort(Range, reserveds, {}, sort_fn);
    }

    // Calculate the total memory range managed by the arena.
    const total_begin = blk: {
        var cur: usize = std.math.maxInt(usize);
        for (avails) |avail| {
            cur = @min(cur, avail.start);
        }
        break :blk cur;
    };
    const total_end = blk: {
        var cur: usize = 0;
        for (avails) |avail| {
            cur = @max(cur, avail.end);
        }
        break :blk cur;
    };
    const total_range = Range{
        .start = total_begin,
        .end = total_end,
    };

    // Allocate buffer for the arena's metadata.
    // TODO: should keep low memory available for other uses?
    const meta_buffer_size = Arena.getRequiredMetaBuffer(total_range);
    const meta_range = blk: {
        for (avails) |avail| {
            var cur = avail;
            while (findFirstUsable(cur, reserveds)) |usable| : (cur = .{
                .start = usable.end,
                .end = avail.end,
            }) {
                if (usable.size() >= meta_buffer_size) break :blk Range{
                    .start = usable.start,
                    .end = usable.start + meta_buffer_size,
                };
            }
        }
        @panic("No suitable meta buffer found");
    };
    const meta_buffer: [*]u8 = @ptrFromInt(phys2virt(meta_range.start));

    // Initialize the arena with meta buffer.
    arena = .new(total_range, meta_buffer[0..meta_buffer_size]);

    // Feed the available regions to the arena,
    for (avails) |avail| {
        rtt.expectEqual(0, avail.start & page_mask);
        rtt.expectEqual(0, avail.end & page_mask);

        // Exclude reserved regions.
        var outer = avail;
        while (findFirstUsable(outer, reserveds)) |outer_usable| : (outer = .{
            .start = outer_usable.end,
            .end = outer.end,
        }) {
            // Exclude meta buffer region.
            var inner = outer_usable;
            while (findFirstUsable(inner, &[1]Range{meta_range})) |inner_usable| : (inner = .{
                .start = inner_usable.end,
                .end = inner.end,
            }) {
                arena.addRegion(inner_usable.start, inner_usable.end);
            }
        }
    }

    // Debug print stats.
    if (log_fn) |f| {
        debugPrintStatistics(f);
    }

    // Runtime test.
    rttTestBuddyAllocator();
}

/// Find the first usable memory region within `avail`, excluding `reserveds` regions.
///
/// `reserveds` must be sorted by the starting address in ascending order.
fn findFirstUsable(avail: Range, reserveds: []const Range) ?Range {
    var cur = @max(page_size, avail.start); // avoid using physical address 0
    const end = avail.start + avail.size();

    for (reserveds) |r| {
        const rstart = r.start;
        const rend = rstart + util.roundup(r.size(), page_size);
        rtt.expectEqual(0, rstart & page_mask);
        rtt.expectEqual(0, rend & page_mask);

        if (end <= rstart) {
            break; // Available region end
        }
        if (rend <= cur) {
            continue; // Reserved region does not overlap
        }
        if (cur < rstart) {
            return .{ .start = cur, .end = rstart };
        }

        cur = @min(rend, end);
    }

    return if (cur < end) .{ .start = cur, .end = end } else null;
}

/// Manages free lists of each order for single memory zone.
///
/// Each page is ensured to be aligned to the order.
const FreeList = struct {
    /// Doubly linked list of free pages.
    link: FreePageLink,
    /// Total number of blocks for the free list.
    ///
    /// This contains both used and free blocks.
    num_total: usize,
    /// Number of blocks in the list.
    num_free: usize = 0,

    /// Doubly linked list of free pages.
    pub const FreePageLink = DoublyLinkedList;
    /// Free page.
    ///
    /// This struct is placed at the beginning of the free pages.
    pub const FreePage = DoublyLinkedList.Node;

    /// Create a new empty free list.
    pub fn new() FreeList {
        return FreeList{
            .link = FreePageLink{},
            .num_total = 0,
        };
    }

    /// Add a new memory region under the management of this list as a free block.
    pub fn addRegion(self: *FreeList, phys: Phys) *FreePage {
        const new_page: *FreePage = phys2page(phys);
        self.insert(new_page);
        self.num_total += 1;
        return new_page;
    }

    /// Allocate a block of pages from the free list.
    pub fn allocBlock(self: *FreeList) Error!*FreePage {
        const page = self.link.popFirst() orelse {
            return Error.OutOfMemory;
        };
        self.num_free -= 1;

        return page;
    }

    /// Detach the given block from the freelist.
    ///
    /// Detached pages are no longer managed by the free list.
    /// Caller MUST ensure that the block is in the list.
    pub fn detachBlock(self: *FreeList, block: *FreePage) void {
        self.link.remove(block);
        self.num_free -= 1;
        self.num_total -= 1;
    }

    /// Detach the first block in the freelist.
    ///
    /// Detached pages are no longer managed by the free list.
    pub fn detachFirstBlock(self: *FreeList) Error!*FreePage {
        const page = self.link.first orelse return Error.OutOfMemory;
        self.detachBlock(page);
        return page;
    }

    /// Add a block of pages to the free list.
    pub fn freeBlock(self: *FreeList, block: []u8) *FreePage {
        const page: *FreePage = @ptrCast(@alignCast(block));
        self.insert(page);
        return page;
    }

    /// Insert the block to the freelist.
    ///
    /// Note that this function does not increment `num_total`.
    fn insert(self: *FreeList, new_page: *FreePage) void {
        self.link.prepend(new_page);
        self.num_free += 1;
    }

    /// Check if the list does not have any free pages.
    pub fn isEmpty(self: *FreeList) bool {
        return self.numFree() == 0;
    }

    /// Get the number of blocks in the freelist.
    ///
    /// Blocks in use are included.
    pub inline fn numTotal(self: FreeList) usize {
        return self.num_total;
    }

    /// Get the number of blocks in the freelist.
    pub inline fn numFree(self: FreeList) usize {
        return self.num_free;
    }

    /// Get the number of blocks in use.
    pub inline fn numInUse(self: FreeList) usize {
        return self.num_total - self.numFree();
    }
};

/// Manages free lists of each order for single memory zone.
const Arena = struct {
    /// Available number of page orders.
    const avail_orders: usize = 24;
    /// If the number of free blocks is larger than this threshold, try merge adjacent blocks.
    const merge_threshold: usize = 10;

    /// Free list for each order.
    lists: [avail_orders]FreeList,
    /// Total memory range managed by this arena.
    total_range: Range,
    /// Metadata for each physical page.
    meta: []align(1) PageMeta,
    /// The first PFN managed by this arena.
    meta_base_index: usize,

    /// Page metadata.
    ///
    /// All physical pages have associated metadata of this type.
    const PageMeta = struct {
        /// If this page is a first page of free block, the order of the block.
        /// Otherwise (in use or not the first page of free block), null.
        order: ?SizeOrder = null,
    };

    /// Create a new arena.
    pub fn new(total: Range, buffer: []u8) Arena {
        rtt.expect(buffer.len >= getRequiredMetaBuffer(total));

        const meta: [*]align(1) PageMeta = @ptrCast(buffer.ptr);
        const meta_length = total.size() / page_size;
        @memset(meta[0..meta_length], .{});

        return .{
            .lists = @splat(.new()),
            .total_range = total,
            .meta = meta[0..meta_length],
            .meta_base_index = total.start / page_size,
        };
    }

    /// Get the size in bytes of the meta buffer required to manage the given range.
    pub fn getRequiredMetaBuffer(total: Range) usize {
        return util.roundup(
            @sizeOf(PageMeta) * (total.size() / page_size),
            page_size,
        );
    }

    /// Add a memory region to the free list.
    pub fn addRegion(self: *Arena, start: Phys, end: Phys) void {
        rtt.expect(start < end);

        var cur_start = start;
        while (true) {
            const size = end - cur_start;
            const orig_order, var remaining = orderFloor(size / page_size);

            // Find the order that matches the alignment.
            var order = orig_order;
            while (order != 0) {
                const mask = getOrderMask(order);
                if (cur_start & mask == 0) break;
                order -= 1;
            }
            remaining += orderToInt(orig_order) - orderToInt(order);

            // Add the region to the free list.
            const new_page = self.registerBlock(cur_start, order);
            self.maybeMergeRecursive(new_page, order);

            cur_start += orderToInt(order) * page_size;
            if (remaining == 0) break;
        }
    }

    /// Allocate the given number of pages.
    pub fn allocPages(self: *Arena, num_pages: usize) Error![]align(page_size) u8 {
        const order = roundUpToOrder(num_pages);
        const free_list = self.getList(order);

        const block = free_list.allocBlock() catch retry: {
            if (order == avail_orders - 1) {
                return Error.OutOfMemory;
            }

            // Split the free list and retry.
            try self.splitRecursive(order + 1);
            break :retry try free_list.allocBlock();
        };

        const ptr: [*]align(page_size) u8 = @ptrCast(@alignCast(block));
        self.setMetaUsed(page2phys(block));

        return ptr[0 .. num_pages * page_size];
    }

    /// Free the given pages to the appropriate list.
    pub fn freePages(self: *Arena, pages: []u8) void {
        if (pages.len == 0) return;

        const phys = virt2phys(@intFromPtr(pages.ptr));
        const order = roundUpToOrder(std.math.divCeil(
            usize,
            pages.len,
            page_size,
        ) catch unreachable);
        rtt.expectEqual(0, phys & getOrderMask(order));
        rtt.expectEqual(null, self.meta[self.getMetaIndex(phys)].order);

        const new_page = self.getList(order).freeBlock(pages);
        self.setMetaFree(phys, order);
        self.maybeMergeRecursive(new_page, order);
    }

    /// Split pages in the `order`-th freelist the `order - 1`-th freelist.
    ///
    /// If the `order`-th freelist is empty, this function is called recursively for larger list.
    ///
    /// Returns error if there's no larger block left to split.
    fn splitRecursive(self: *Arena, order: SizeOrder) Error!void {
        rtt.expect(order != 0);

        const lower_order = order - 1;
        const free_list = self.getList(order);

        // Ensure that the freelist is not empty.
        if (free_list.isEmpty()) {
            if (order == avail_orders - 1) return Error.OutOfMemory;

            try self.splitRecursive(order + 1);
            rtt.expectEqual(false, free_list.isEmpty());
        }

        const block = free_list.detachFirstBlock() catch {
            @panic("BuddyAllocator: failed to split the free list.");
        };

        const block_phys = page2phys(block);
        const block_size = orderToInt(lower_order) * page_size;
        const num_blocks = (orderToInt(order) * page_size) / block_size;
        rtt.expectEqual(2, num_blocks);
        for (0..2) |i| {
            // We dont't merge here.
            _ = self.registerBlock(block_phys + i * block_size, lower_order);
        }
    }

    /// Try ty merge blocks adjacent to the given block recursively.
    fn maybeMergeRecursive(self: *Arena, page: *FreeList.FreePage, order: SizeOrder) void {
        // If the order is the largest, we can't merge anymore.
        if (order == avail_orders - 1) return;
        // If the number of free blocks is small, we don't merge.
        if (self.getList(order).numFree() < merge_threshold) return;

        // Find the adjacent block.
        const higher_order = order + 1;
        const phys = page2phys(page);
        const buddy = phys ^ getOrderSize(order);
        if (!self.total_range.contains(buddy)) {
            @branchHint(.cold);
            return;
        }
        if (self.meta[self.getMetaIndex(buddy)].order != order) {
            return;
        }

        // If we find the adjacent block, merge them recursively.
        const lower_list = self.getList(order);
        lower_list.detachBlock(page);
        lower_list.detachBlock(phys2page(buddy));

        const new_page = self.registerBlock(@min(phys, buddy), higher_order);
        self.setMetaUsed(@max(phys, buddy));

        self.maybeMergeRecursive(new_page, higher_order);
    }

    /// Put a new free block under the management.
    ///
    /// This function does not try to merge the block.
    fn registerBlock(self: *Arena, phys: Phys, order: SizeOrder) *FreeList.FreePage {
        const page = self.getList(order).addRegion(phys);
        self.setMetaFree(phys, order);
        return page;
    }

    /// Get the free list for the given order.
    inline fn getList(self: *Arena, order: SizeOrder) *FreeList {
        return &self.lists[order];
    }

    /// Convert the number of pages to the order.
    ///
    /// If the num is not a power of 2, the order is rounded down and the remaining size is returned.
    /// If the order exceeds the available orders, the order is clamped to the max.
    /// Returns the pair of the order and the remaining number of pages.
    fn orderFloor(num_pages: usize) struct { SizeOrder, usize } {
        rtt.expect(num_pages != 0);

        var order = std.math.log2_int(usize, num_pages);
        if (order >= avail_orders) {
            order = avail_orders - 1;
        }
        const remaining = num_pages - (@as(usize, 1) << order);

        return .{ @intCast(order), remaining };
    }

    /// Get the number of pages for the given order.
    fn orderToInt(order: SizeOrder) usize {
        return @as(usize, 1) << @intCast(order);
    }

    /// Get the size in bytes of a single block of the order.
    fn getOrderSize(order: SizeOrder) usize {
        return orderToInt(order) << page_shift;
    }

    /// Get the address mask for the order.
    fn getOrderMask(order: SizeOrder) usize {
        return getOrderSize(order) - 1;
    }

    /// Align the number of pages to the order.
    inline fn roundUpToOrder(num_pages: usize) SizeOrder {
        rtt.expect(num_pages != 0);
        return std.math.log2_int_ceil(usize, num_pages);
    }

    /// Mark the physical page as a free block of the given order.
    fn setMetaFree(self: *Arena, phys: Phys, order: SizeOrder) void {
        const index = self.getMetaIndex(phys);
        self.meta[index] = .{ .order = order };
    }

    /// Mark the physical page as in-use.
    fn setMetaUsed(self: *Arena, phys: Phys) void {
        const index = self.getMetaIndex(phys);
        self.meta[index] = .{ .order = null };
    }

    /// Get the index of the metadata for the given physical address.
    fn getMetaIndex(self: *const Arena, phys: Phys) usize {
        rtt.expectEqual(0, phys & page_mask);
        return (phys >> page_shift) - self.meta_base_index;
    }
};

/// Convert the given virtual address to physical address.
fn virt2phys(vaddr: usize) usize {
    return vaddr - vmap.linear.start;
}

/// Convert the given physical address to virtual address.
fn phys2virt(paddr: usize) usize {
    return paddr + vmap.linear.start;
}

/// Get the physical address of the given free page.
fn page2phys(page: *FreeList.FreePage) Phys {
    return virt2phys(@intFromPtr(page));
}

/// Get the free page at the given physical address.
fn phys2page(phys: Phys) *FreeList.FreePage {
    return @ptrFromInt(phys2virt(phys));
}

/// Get current memory statistics from the buddy allocator.
pub fn getStats() mem.Stats {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    var total: usize = 0;
    var free: usize = 0;
    for (arena.lists, 0..) |list, order| {
        const pages_per_block = Arena.orderToInt(@intCast(order));
        total += pages_per_block * list.numTotal();
        free += pages_per_block * list.numFree();
    }

    return .{
        .total_bytes = total * page_size,
        .free_bytes = free * page_size,
    };
}

// =============================================================
// Interface
// =============================================================

fn allocPages(_: *anyopaque, num_pages: usize) Error![]align(page_size) u8 {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    const vpages = try arena.allocPages(num_pages);
    const pptr: [*]u8 = @ptrFromInt(virt2phys(@intFromPtr(vpages.ptr)));
    return @alignCast(pptr[0..vpages.len]);
}

fn freePages(_: *anyopaque, pages: []u8) void {
    if (pages.len == 0) return;

    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    const vptr: [*]u8 = @ptrFromInt(phys2virt(@intFromPtr(pages.ptr)));
    const vpages: []align(page_size) u8 = @alignCast(vptr[0..pages.len]);

    arena.freePages(vpages);
}

fn virt2physInterface(_: *const anyopaque, vaddr: usize) usize {
    return virt2phys(vaddr);
}

fn phys2virtInterface(_: *const anyopaque, paddr: usize) usize {
    return phys2virt(paddr);
}

// =============================================================
// Debug
// =============================================================

// Debug print the statistics of managed regions.
fn debugPrintStatistics(comptime log_fn: urd.LogFn) void {
    log_fn("Statistics of Buddy Allocator's initial state:", .{});
    log_fn(
        "{s: <7}                   Used / Total",
        .{"Normal"},
    );

    var total_pages: usize = 0;
    var total_inuse_pages: usize = 0;
    for (arena.lists, 0..) |list, order| {
        const page_unit = Arena.orderToInt(@intCast(order));
        const pages = page_unit * list.numTotal();
        const inuse_pages = page_unit * list.numInUse();
        total_pages += pages;
        total_inuse_pages += inuse_pages;
        log_fn(
            "   {d: >2}: {d: >7} ({d: >7} pages) / {d: >7} ({d: >7} pages)",
            .{ order, list.numInUse(), inuse_pages, list.numTotal(), pages },
        );
    }

    log_fn(
        "    >             {d:>8} MiB / {d: >8} MiB",
        .{ total_inuse_pages * page_size / units.mib, total_pages * page_size / units.mib },
    );
}

// =============================================================
// Tests
// =============================================================

const testing = std.testing;
const rtt = common.rtt;

const TestingAllocatedList = DoublyLinkedList;
const TestingAllocatedNode = TestingAllocatedList.Node;

/// Runtime test for BuddyAllocator.
fn rttTestBuddyAllocator() void {
    if (!urd.enable_rtt) return;

    const allocator = interface;

    // The metadata must be consistent right after the initialization.
    rttCheckMeta();

    // Allocate 3 pages (from 2-th freelist) and check the alignment.
    {
        const page = allocator.allocPagesV(3) catch {
            @panic("Unexpected failure in rttTestBuddyAllocator()");
        };
        // Must be aligned to 16 KiB.
        rtt.expectEqual(0, @intFromPtr(page.ptr) & 0x3_FFF);
        allocator.freePagesV(page);
    }

    // Record the initial state.
    var allocated_pages_order0 = TestingAllocatedList{};
    const num_free_order0 = arena.lists[0].numFree();
    const num_inuse_order0 = arena.lists[0].numInUse();
    const num_free_order1 = arena.lists[1].numFree();
    const num_inuse_order1 = arena.lists[1].numInUse();
    const num_free_order2 = arena.lists[2].numFree();
    const num_inuse_order2 = arena.lists[2].numInUse();

    if (num_free_order1 == 0 and num_free_order2 == 0) {
        // No pages to test.
        return;
    }

    // Consume all pages from 0-th freelist.
    {
        for (0..num_free_order0) |_| {
            _ = rttAllocatePage(&allocated_pages_order0, allocator);
        }
        rtt.expectEqual(0, arena.lists[0].link.len());
        rtt.expectEqual(null, arena.lists[0].link.first);
        rtt.expectEqual(null, arena.lists[0].link.last);
    }

    // Split pages in the 1-st freelist to the 0-th.
    {
        const page1 = rttAllocatePage(&allocated_pages_order0, allocator);
        const page2 = rttAllocatePage(&allocated_pages_order0, allocator);

        // Two pages must be contiguous because they are split from the same block.
        const distance = if (@intFromPtr(page1.ptr) < @intFromPtr(page2.ptr))
            @intFromPtr(page2.ptr) - @intFromPtr(page1.ptr)
        else
            @intFromPtr(page1.ptr) - @intFromPtr(page2.ptr);
        rtt.expectEqual(page_size, distance);
    }

    // Free all pages and see if they are merged.
    // The state of the arena may change due to split & merge logic.
    {
        // Free pages in the order of allocation.
        var cur = allocated_pages_order0.first;
        while (cur) |c| {
            const page: [*]u8 = @ptrCast(c);
            cur = c.next; // We have to store the value here before the page is freed.
            allocator.freePagesV(page[0..page_size]);
        }

        rtt.expectEqual(
            num_inuse_order0 * 1 + num_inuse_order1 * 2 + num_inuse_order2 * 4,
            arena.lists[0].numInUse() * 1 + arena.lists[1].numInUse() * 2 + arena.lists[2].numInUse() * 4,
        );
        rtt.expectEqual(
            num_free_order0 * 1 + num_free_order1 * 2 + num_free_order2 * 4,
            arena.lists[0].numFree() * 1 + arena.lists[1].numFree() * 2 + arena.lists[2].numFree() * 4,
        );
    }

    // Splits and merges must keep the metadata consistent.
    rttCheckMeta();
}

/// Check if the page metadata and the freelists are consistent.
fn rttCheckMeta() void {
    if (!urd.enable_rtt) return;

    var num_free_blocks: usize = 0;
    for (&arena.lists, 0..) |*list, order| {
        const expected: SizeOrder = @intCast(order);

        var count: usize = 0;
        var cur = list.link.first;
        while (cur) |node| : (cur = node.next) {
            const phys = page2phys(node);
            rtt.expectEqual(
                0,
                phys & Arena.getOrderMask(@intCast(order)),
            );
            rtt.expectEqual(
                expected,
                arena.meta[arena.getMetaIndex(phys)].order,
            );
            count += 1;
        }

        rtt.expectEqual(list.numFree(), count);
        num_free_blocks += count;
    }

    var num_heads: usize = 0;
    for (arena.meta) |meta| {
        if (meta.order != null) num_heads += 1;
    }
    rtt.expectEqual(num_free_blocks, num_heads);
}

fn rttAllocatePage(list: *TestingAllocatedList, allocator: PageAllocator) []align(page_size) u8 {
    const page = allocator.allocPagesV(1) catch {
        @panic("Unexpected failure in rttAllocatePage()");
    };
    const new_page: *TestingAllocatedNode = @ptrCast(page.ptr);
    list.append(new_page);
    return page;
}

test "Arena.getOrderMask" {
    try testing.expectEqual(0xFFF, Arena.getOrderMask(0));
    try testing.expectEqual(0x1FFF, Arena.getOrderMask(1));
    try testing.expectEqual(0x3FFF, Arena.getOrderMask(2));
    try testing.expectEqual(0x7FFF, Arena.getOrderMask(3));
    try testing.expectEqual(0xFFFF, Arena.getOrderMask(4));
    try testing.expectEqual(0x1FFFF, Arena.getOrderMask(5));
    try testing.expectEqual(0x3FFFF, Arena.getOrderMask(6));
    try testing.expectEqual(0x7FFFF, Arena.getOrderMask(7));
    try testing.expectEqual(0xFFFFF, Arena.getOrderMask(8));
    try testing.expectEqual(0x1FFFFF, Arena.getOrderMask(9));
    try testing.expectEqual(0x3FFFFF, Arena.getOrderMask(10));
}

test "Arena.orderFloor" {
    try testing.expectEqual(.{ 0, 0 }, Arena.orderFloor(1));
    try testing.expectEqual(.{ 1, 0 }, Arena.orderFloor(2));
    try testing.expectEqual(.{ 1, 1 }, Arena.orderFloor(3));
    try testing.expectEqual(.{ 2, 0 }, Arena.orderFloor(4));
}

test "Arena.orderToInt" {
    try testing.expectEqual(1, Arena.orderToInt(0));
    try testing.expectEqual(2, Arena.orderToInt(1));
    try testing.expectEqual(4, Arena.orderToInt(2));
    try testing.expectEqual(8, Arena.orderToInt(3));
}

test "Arena.roundUpToOrder" {
    try testing.expectEqual(0, Arena.roundUpToOrder(1));
    try testing.expectEqual(1, Arena.roundUpToOrder(2));
    try testing.expectEqual(2, Arena.roundUpToOrder(3));
    try testing.expectEqual(2, Arena.roundUpToOrder(4));
    try testing.expectEqual(3, Arena.roundUpToOrder(5));
    try testing.expectEqual(3, Arena.roundUpToOrder(8));
    try testing.expectEqual(4, Arena.roundUpToOrder(9));
    try testing.expectEqual(4, Arena.roundUpToOrder(16));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const DoublyLinkedList = std.DoublyLinkedList;
const common = @import("common");
const units = common.units;
const util = common.util;
const PageAllocator = common.mem.PageAllocator;
const Range = common.Range;
const urd = @import("urthr");
const mem = urd.mem;
const SpinLock = urd.sync.SpinLock;
const vmap = @import("vmemmap.zig");
