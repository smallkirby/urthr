//! Page cache for regular file data.
//!
//! File contents are cached in page-sized units keyed by (inode, page index).

/// Size of a cached page.
pub const page_size = urd.mem.page_size;

/// Per-inode state of the page cache.
pub const InodeCache = struct {
    /// Pages cached for the inode.
    pages: Page.InodeList = .{},
    /// Number of dirty pages.
    ndirty_pages: usize = 0,
    /// File size after dirty pages are written back.
    ///
    /// Valid only when there's any dirty pages.
    /// Otherwise, the size is same as in-memory inode's size.
    disk_size: usize = 0,
    /// File used to write back dirty pages.
    ///
    /// Set only when the inode has dirty pages.
    flusher: ?*File = null,
    /// List head in the list of the inodes that have dirty pages.
    dirty: DirtyList.Head = .{},

    const DirtyList = InlineDoublyLinkedList(InodeCache, "dirty");

    /// Get the inode this cache belongs to.
    fn inode(self: *InodeCache) *Inode {
        return @fieldParentPtr("cache", self);
    }

    /// Whether the inode has dirty pages.
    fn isDirty(self: *const InodeCache) bool {
        return self.flusher != null;
    }
};

/// Maximum number of cached pages.
const max_pages = 0x2_0000;
/// Maximum number of dirty pages.
const max_dirty = 0x2000;
/// Maximum number of pages read by a single request to the filesystem.
const readahead_pages = 32;
/// Number of hash buckets.
const num_buckets = 1 << 15;

comptime {
    urd.comptimeAssert(max_dirty <= max_pages, "", .{});
    urd.comptimeAssert(std.math.isPowerOfTwo(num_buckets), "", .{});
}

/// Cached page information.
const Page = struct {
    /// Inode that owns this page.
    inode: *Inode,
    /// Index of this page in the file.
    index: usize,
    /// Page data.
    data: []u8,
    /// Number of valid bytes in `data`. The rest is zero.
    len: usize,
    /// Whether the page has pages that are not written back to the device.
    dirty: bool = false,

    /// Next page in the hash bucket or in the free list.
    next: ?*Page,
    /// List head in the LRU list.
    lru: LruList.Head = .{},
    /// List head in the list of the pages of the same inode.
    ino: InodeList.Head = .{},

    const LruList = InlineDoublyLinkedList(Page, "lru");
    const InodeList = InlineDoublyLinkedList(Page, "ino");

    /// Mark the page as dirty.
    pub fn setDirty(self: *Page) void {
        if (self.dirty) return;

        self.dirty = true;
        self.inode.cache.ndirty_pages += 1;
        dirty_count += 1;
    }

    /// Mark the page as clean.
    pub fn setClean(self: *Page) void {
        if (!self.dirty) return;

        self.dirty = false;
        self.inode.cache.ndirty_pages -= 1;
        dirty_count -= 1;
    }
};

/// Protects all the state below.
var mutex: Mutex = .{};
/// Hash buckets.
///
/// Buckets are indexed by the hash of the (inode, page index) pair.
var buckets: []?*Page = &.{};
/// Scratch buffer to read pages from the filesystem.
var scratch: []u8 = &.{};
/// All cached pages. The most recently used page is the first.
var lru: Page.LruList = .{};
/// Pages that hold a data buffer but are not in use.
var free_list: ?*Page = null;
/// Number of allocated pages including free ones.
var num_pages: usize = 0;
/// Number of dirty pages.
var dirty_count: usize = 0;
/// Inodes that have dirty pages.
var dirty_inodes: InodeCache.DirtyList = .{};

/// Statistics.
const Stats = struct {
    /// The number of cache hits.
    hits: u64 = 0,
    /// The number of cache misses.
    misses: u64 = 0,
    /// The number of pages evicted from the cache.
    evictions: u64 = 0,
};
var stats: Stats = .{};

/// Read data of a regular file through the cache.
///
/// Returns the number of bytes read.
pub fn read(file: *File, buf: []u8, pos: usize) Error!usize {
    const inode = file.path.dentry.getInode();
    const size = inode.size;
    if (pos >= size) return 0;
    const total = @min(buf.len, size - pos);

    mutex.lock();
    defer mutex.unlock();
    try ensureInit();

    var done: usize = 0;
    while (done < total) {
        const cur = pos + done;
        const index = cur / page_size;
        const off = cur % page_size;

        const page = try getPage(
            file,
            inode,
            index,
            size,
            false,
        );
        if (off >= page.len) break;

        const n = @min(page.len - off, total - done);
        uaccess.copy(buf[done..], page.data[off..], n) catch {
            return Error.IoError;
        };
        touch(page);
        done += n;
    }

    return done;
}

/// Write data to a regular file through the cache.
///
/// Data is not written to the device until the pages are flushed.
/// Returns the number of bytes written.
pub fn write(file: *File, buf: []const u8, pos: usize) Error!usize {
    if (file.ops.write == null) return Error.Unsupported;
    if (buf.len == 0) return 0;

    const end = std.math.add(usize, pos, buf.len) catch {
        return Error.InvalidArgument;
    };
    if (end > std.math.maxInt(u32)) {
        return Error.InvalidArgument;
    }

    const inode = file.path.dentry.getInode();
    if (dirty_count >= max_dirty) {
        try flushAll();
    }

    mutex.lock();
    defer mutex.unlock();
    try ensureInit();

    if (!inode.cache.isDirty()) {
        try markDirty(file, inode);
    }

    // The last partial page gets longer if the file grows.
    const old_size = inode.size;
    const new_size = @max(old_size, end);
    if (new_size > old_size and
        old_size % page_size != 0 and
        pos / page_size > old_size / page_size)
    {
        if (find(inode, old_size / page_size)) |p| {
            p.len = expectedLen(new_size, p.index);
        }
    }

    var done: usize = 0;
    while (done < buf.len) {
        const cur = pos + done;
        const index = cur / page_size;
        const off = cur % page_size;
        const n = @min(page_size - off, buf.len - done);

        const page = try getPage(
            file,
            inode,
            index,
            old_size,
            off == 0 and n == page_size,
        );
        uaccess.copy(page.data[off..], buf[done..], n) catch {
            inode.size = @max(old_size, pos + done);
            return Error.IoError;
        };
        page.len = expectedLen(new_size, index);
        page.setDirty();
        touch(page);

        done += n;
    }

    inode.size = new_size;

    return done;
}

/// Write back all the dirty pages of the inode to the filesystem.
pub fn flush(inode: *Inode) Error!void {
    if (!inode.cache.isDirty()) return;

    const released = blk: {
        mutex.lock();
        defer mutex.unlock();

        break :blk flushLocked(inode) catch |err| {
            return err;
        };
    };

    if (released) |flusher| {
        flusher.unref();
    }
}

/// Write back all the dirty pages of all the inodes to the filesystem.
pub fn flushAll() Error!void {
    var result: Error!void = {};
    var remaining = blk: {
        mutex.lock();
        defer mutex.unlock();
        break :blk dirty_inodes.len;
    };

    while (remaining > 0) : (remaining -= 1) {
        const released = outer: {
            mutex.lock();
            defer mutex.unlock();

            const cache = dirty_inodes.first orelse break;
            const inode = cache.inode();

            break :outer flushLocked(inode) catch |err| {
                // Preserve the first error
                if (result) |_| result = err else |_| {}

                // Move the failed inode to the tail.
                dirty_inodes.remove(cache);
                dirty_inodes.append(cache);
                break :outer null;
            };
        };

        if (released) |flusher| {
            flusher.unref();
        }
    }

    return result;
}

/// Write back all the dirty pages of the inode.
///
/// On success, returns the file used to write back,
/// that the caller must ensure to unref without the mutex.
fn flushLocked(inode: *Inode) Error!?*File {
    rtt.expect(mutex.isLocked());

    const cache = &inode.cache;
    if (!cache.isDirty()) return null;

    const file = cache.flusher.?;
    const writer = file.ops.write.?;
    const inmem_size = inode.size;

    // TODO: HACK: `writer` depends on `inode.size`,
    // so we temporarily update the inode size to match the disk size.
    // TODO: This change is visible to other threads.
    // Must add an API that can take the temporary inode size change into account.
    inode.size = cache.disk_size;
    defer {
        cache.disk_size = inode.size;
        inode.size = inmem_size;
    }

    if (cache.ndirty_pages != 0) {
        const allocator = urd.mem.bin;
        const dpages = allocator.alloc(*Page, cache.ndirty_pages) catch {
            return Error.OutOfMemory;
        };
        defer allocator.free(dpages);

        // Sort dirty pages by their index to optimize sequential writes.
        var ndirty: usize = 0;
        var iter = cache.pages.iter();
        while (iter.next()) |p| {
            if (p.dirty) {
                dpages[ndirty] = p;
                ndirty += 1;
            }
        }
        std.mem.sort(*Page, dpages[0..ndirty], {}, struct {
            fn lessThan(_: void, a: *Page, b: *Page) bool {
                return a.index < b.index;
            }
        }.lessThan);

        // Write back contiguous pages at once.
        var i: usize = 0;
        while (i < ndirty) {
            // Collect contiguous dirty pages.
            var j = i;
            var total: usize = 0;
            while (j < ndirty and
                j - i < readahead_pages and
                dpages[j].index == dpages[i].index + (j - i))
            {
                const len = expectedLen(inmem_size, dpages[j].index);
                @memcpy(scratch[total..][0..len], dpages[j].data[0..len]);
                total += len;
                j += 1;
                if (len < page_size) break;
            }

            // Perform write back to the filesystem.
            if (total != 0) _ = try writer(
                file,
                scratch[0..total],
                dpages[i].index * page_size,
            );
            for (dpages[i..j]) |p| {
                p.setClean();
            }
            i = j;
        }
    }

    // File has been grown in-memory, but not written and not dirty.
    if (inode.size < inmem_size) {
        if (file.ops.truncate) |truncater| {
            try truncater(file, inmem_size);
        } else {
            return Error.Unsupported;
        }
    }

    cache.flusher = null;
    dirty_inodes.remove(cache);

    return file;
}

/// Change the size of the file.
///
/// If the file has dirty pages and the filesystem does not have to change the size,
/// the size is changed only in the cache. Otherwise, dirty pages are written back first.
pub fn truncate(file: *File, new_size: usize) Error!void {
    const inode = file.path.dentry.getInode();

    // Try to perform in-memory truncation.
    if (truncateInCache(inode, new_size)) {
        return;
    }

    // Request the filesystem to truncate.
    try flush(inode);
    if (file.ops.truncate) |truncater| {
        try truncater(file, new_size);
    } else {
        return Error.Unsupported;
    }
    discardPagesBeyond(inode, new_size);
}

/// Change the size of the file that has dirty pages only in the cache.
///
/// Returns false when any of the following condition is met:
/// - the file is clean (no pages are dirty).
/// - new size is smaller than the current on-disk size.
///
/// In this case, we need to request the filesystem to change the size immediately.
fn truncateInCache(inode: *Inode, new_size: usize) bool {
    mutex.lock();
    defer mutex.unlock();

    if (!inode.cache.isDirty() or new_size < inode.cache.disk_size) {
        return false;
    }

    // New size is larger than old size on device, but smaller than the current in-memory size.
    // Remove the pages that are beyond the new size (no need to write back).
    const old_size = inode.size;
    if (new_size < old_size) {
        var iter = inode.cache.pages.iter();
        while (iter.next()) |page| {
            if (page.index * page_size >= new_size) remove(page);
        }
    }
    // Adjust the size of last partially dirty page if necessary.
    const tail = @min(old_size, new_size);
    if (tail % page_size != 0) {
        if (find(inode, tail / page_size)) |p| {
            @memset(p.data[tail % page_size ..], 0);
            p.len = expectedLen(new_size, p.index);
        }
    }

    inode.size = new_size;
    return true;
}

/// Drop the cached pages beyond the new size of the file without writing them back.
fn discardPagesBeyond(inode: *Inode, new_size: usize) void {
    if (inode.cache.pages.isEmpty()) return;

    mutex.lock();
    defer mutex.unlock();

    var iter = inode.cache.pages.iter();
    while (iter.next()) |page| {
        if (page.index * page_size >= new_size) remove(page);
    }
}

/// Discard the cached pages of the unlinked file without writing them back.
///
/// Does nothing if the file is still referenced.
pub fn discardUnlinked(dentry: *Dentry) void {
    const inode = dentry.getInode();

    if (inode.cache.pages.isEmpty() and !inode.cache.isDirty()) {
        return; // nothing to discard
    }

    const flusher = blk: {
        mutex.lock();
        defer mutex.unlock();

        // Check if someone is still holding a reference.
        const nrefs: usize = if (inode.cache.isDirty())
            2 // flusher + caller's dentry
        else
            1; // caller's dentry only
        if (dentry.refcnt.load(.acquire) != nrefs) {
            return;
        }

        // Discard cached pages.
        while (inode.cache.pages.first) |page| remove(page);
        if (!inode.cache.isDirty()) return;

        // Unlink from dirty list.
        dirty_inodes.remove(&inode.cache);

        const f = inode.cache.flusher.?;
        inode.cache.flusher = null;
        break :blk f;
    };

    flusher.unref();
}

/// Drop all the cached pages of the inode.
///
/// Must be called before the inode is destroyed.
pub fn dropInode(inode: *Inode) void {
    if (inode.cache.pages.isEmpty()) return;

    mutex.lock();
    defer mutex.unlock();

    while (inode.cache.pages.first) |page| remove(page);
}

/// Read the page at `index` and following pages from the filesystem.
///
/// Returns the page at `index`.
fn fill(file: *File, index: usize, size: usize) Error!*Page {
    const inode = file.path.dentry.getInode();

    // The page exists only in page cache, not on the device yet.
    const limit = getDiskSize(inode);
    if (index * page_size >= limit) {
        const page = find(inode, index) orelse try newPage(inode, index);
        page.len = expectedLen(size, index);
        touch(page);
        return page;
    }

    // Read ahead until the end of the file or until an already valid page.
    const last = (limit - 1) / page_size;
    var count: usize = 1;
    while (count < readahead_pages and index + count <= last) : (count += 1) {
        if (find(inode, index + count)) |p| {
            if (p.dirty or p.len == expectedLen(size, index + count)) break;
        }
    }

    const start = index * page_size;
    const want = @min(count * page_size, limit - start);
    const n = try file.ops.read(file, scratch[0..want], start);

    // Fill the page cache with the read data.
    var first: ?*Page = null;
    for (0..count) |i| {
        const base = i * page_size;
        if (base >= n) break;
        const copy = @min(page_size, n - base);
        const len = if (n == want) expectedLen(size, index + i) else copy;

        const page = find(inode, index + i) orelse try newPage(inode, index + i);
        if (page.dirty) continue;

        @memcpy(page.data[0..copy], scratch[base..][0..copy]);
        @memset(page.data[copy..], 0);
        page.len = len;
        touch(page);

        if (i == 0) first = page;
    }

    return first orelse Error.IoError;
}

/// Number of bytes that the page at `index` has when the file is `size` bytes.
fn expectedLen(size: usize, index: usize) usize {
    return if (size <= index * page_size)
        0
    else
        @min(page_size, size - index * page_size);
}

/// Ensure that the page cache mechanism is initialized.
///
/// If not, initialize it by allocating the necessary resources.
fn ensureInit() Error!void {
    if (buckets.len != 0) return;

    const allocator = urd.mem.bin;
    const b = allocator.alloc(?*Page, num_buckets) catch return Error.OutOfMemory;
    errdefer allocator.free(b);
    @memset(b, null);
    scratch = allocator.alloc(u8, readahead_pages * page_size) catch return Error.OutOfMemory;
    buckets = b;
}

/// Calculate the bucket index for the given inode and page index.
fn bucketOf(inode: *const Inode, index: usize) usize {
    const key = [2]usize{ @intFromPtr(inode), index };
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&key)) & (num_buckets - 1);
}

/// Find a page cache corresponding to the given inode and page index.
///
/// Returns null if the page is not found in the cache.
fn find(inode: *const Inode, index: usize) ?*Page {
    var cur = buckets[bucketOf(inode, index)];
    while (cur) |p| : (cur = p.next) {
        if (p.inode == inode and p.index == index) return p;
    } else return null;
}

/// Get a page for the given key and register it in the cache.
fn newPage(inode: *Inode, index: usize) Error!*Page {
    const page = try takePage();
    const bucket = &buckets[bucketOf(inode, index)];

    page.inode = inode;
    page.index = index;
    page.len = 0;
    page.dirty = false;
    @memset(page.data, 0);

    page.next = bucket.*;
    bucket.* = page;

    inode.cache.pages.prepend(page);
    lru.prepend(page);

    return page;
}

/// Get the page, reading it from the filesystem unless it is about to be overwritten entirely.
///
/// `index` is the index of the page within the file.
/// `size` is the current size of the file.
/// `overwrite` indicates whether the page will be completely overwritten.
fn getPage(file: *File, inode: *Inode, index: usize, size: usize, overwrite: bool) Error!*Page {
    // Check if the exact page is already in the cache.
    const found = find(inode, index);
    if (found) |p| {
        if (p.len == expectedLen(size, index)) {
            stats.hits += 1;
            return p;
        }
    }
    stats.misses += 1;

    // If the page is about to be overwritten entirely,
    // we don't need to read it from the filesystem.
    if (overwrite) {
        return found orelse newPage(inode, index);
    } else {
        return fill(file, index, size);
    }
}

/// Get an unused page, evicting the least recently used one if necessary.
fn takePage() Error!*Page {
    // No free list, and no available pages to allocate.
    if (free_list == null and num_pages >= max_pages) {
        // Find a clean page to evict.
        var victim = lru.last;
        while (victim) |p| : (victim = p.lru.prev) {
            if (!p.dirty) break;
        }

        stats.evictions += 1;
        remove(victim orelse return Error.OutOfMemory);
    }

    // We have a free page available.
    if (free_list) |p| {
        free_list = p.next;
        return p;
    }

    // Allocate a new page.
    const allocator = urd.mem.bin;
    const page = allocator.create(Page) catch return Error.OutOfMemory;
    errdefer allocator.destroy(page);
    page.data = allocator.alloc(u8, page_size) catch return Error.OutOfMemory;
    num_pages += 1;
    return page;
}

/// Unregister the page from the cache and put it to the free list.
fn remove(page: *Page) void {
    page.setClean();

    // Remove from the hash bucket.
    var link = &buckets[bucketOf(page.inode, page.index)];
    while (link.*) |p| : (link = &p.next) {
        if (p == page) {
            link.* = p.next;
            break;
        }
    }

    // Remove from the inode's page list and LRU list.
    page.inode.cache.pages.remove(page);
    lru.remove(page);

    // Add to the free list.
    page.next = free_list;
    free_list = page;
}

/// Mark the page as the most recently used.
fn touch(page: *Page) void {
    if (lru.first == page) return;

    lru.remove(page);
    lru.prepend(page);
}

/// Prepare the inode to have dirty pages.
fn markDirty(file: *File, inode: *Inode) Error!void {
    // Open the file for writing back dirty pages later.
    const flusher = try File.open(
        file.path,
        .{},
        file.allocator,
    );
    // Append to the list of dirty inodes.
    dirty_inodes.append(&inode.cache);
    inode.cache.disk_size = inode.size;
    inode.cache.flusher = flusher;
}

/// Get the file size that the device knows.
///
/// Uncommitted dirty pages can change the in-device file size.
/// This function always returns the size after dirty pages are written back.
fn getDiskSize(inode: *const Inode) usize {
    return if (inode.cache.isDirty()) inode.cache.disk_size else inode.size;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const rtt = common.rtt;
const InlineDoublyLinkedList = common.typing.InlineDoublyLinkedList;
const urd = @import("urthr");
const fs = urd.fs;
const Error = fs.Error;
const Dentry = fs.Dentry;
const File = fs.File;
const Inode = fs.Inode;
const Mutex = urd.sync.Mutex;
const uaccess = urd.uaccess;
