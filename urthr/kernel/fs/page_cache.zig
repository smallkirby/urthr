//! Page cache for regular file data.
//!
//! File contents are cached in page-sized units keyed by (inode, page index).

/// Size of a cached page.
pub const page_size = urd.mem.page_size;

/// Per-inode state of the page cache.
pub const InodeCache = struct {
    /// Pages cached for the inode.
    pages: Page.InodeList = .{},
};

/// Maximum number of cached pages.
const max_pages = 0x2_0000;
/// Maximum number of pages read by a single request to the filesystem.
const readahead_pages = 32;
/// Number of hash buckets. Must be a power of two.
const num_buckets = 1 << 15;

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

    /// Next page in the hash bucket or in the free list.
    next: ?*Page,
    /// List head in the LRU list.
    lru: LruList.Head = .{},
    /// List head in the list of the pages of the same inode.
    ino: InodeList.Head = .{},

    const LruList = InlineDoublyLinkedList(Page, "lru");
    const InodeList = InlineDoublyLinkedList(Page, "ino");
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

        const page = if (find(inode, index)) |p| blk: {
            if (p.len == expectedLen(size, index)) {
                stats.hits += 1;
                break :blk p;
            }
            stats.misses += 1;
            break :blk try fill(file, index, size);
        } else blk: {
            stats.misses += 1;
            break :blk try fill(file, index, size);
        };

        if (off >= page.len) break;

        const n = @min(page.len - off, total - done);
        uaccess.copy(buf[done..], page.data[off..], n) catch return Error.IoError;
        touch(page);
        done += n;
    }

    return done;
}

/// Write data to a regular file and reflect it into the cache.
///
/// Returns the number of bytes written.
pub fn write(file: *File, buf: []const u8, pos: usize) Error!usize {
    const f = file.ops.write orelse return Error.Unsupported;
    const n = try f(file, buf, pos);
    update(file.path.dentry.getInode(), buf[0..n], pos);
    return n;
}

/// Reflect data written to the filesystem into the cache.
fn update(inode: *Inode, data: []const u8, pos: usize) void {
    if (data.len == 0) return;

    mutex.lock();
    defer mutex.unlock();
    if (buckets.len == 0) return;

    const end = pos + data.len;
    var index = pos / page_size;
    while (index * page_size < end) : (index += 1) {
        const base = index * page_size;
        const off_from = @max(pos, base) - base;
        const off_to = @min(end, base + page_size) - base;
        const src = data[base + off_from - pos ..][0 .. off_to - off_from];

        if (find(inode, index)) |page| {
            // A hole between the cached data and the written data.
            if (off_from > page.len) {
                remove(page);
                continue;
            }
            // Cache new data into the existing page.
            uaccess.copy(page.data[off_from..], src, src.len) catch {
                remove(page);
                continue;
            };
            page.len = @max(page.len, off_to);
            touch(page);
        } else if (off_from == 0 and (off_to == page_size or base + off_to >= inode.size)) {
            // Newly written whole page.
            const page = newPage(inode, index) catch continue;
            uaccess.copy(page.data, src, src.len) catch {
                remove(page);
                continue;
            };
            page.len = off_to;
        }
    }
}

/// Drop the cached pages beyond the new size of the file.
pub fn truncate(inode: *Inode, new_size: usize) void {
    if (inode.cache.pages.isEmpty()) return;

    mutex.lock();
    defer mutex.unlock();

    var iter = inode.cache.pages.iter();
    while (iter.next()) |page| {
        if (page.index * page_size >= new_size) remove(page);
    }
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

    // Read ahead until the end of the file or until an already valid page.
    const last = (size - 1) / page_size;
    var count: usize = 1;
    while (count < readahead_pages and index + count <= last) : (count += 1) {
        if (find(inode, index + count)) |p| {
            if (p.len == expectedLen(size, index + count)) break;
        }
    }

    const start = index * page_size;
    const want = @min(count * page_size, size - start);
    const n = try file.ops.read(file, scratch[0..want], start);

    // Fill the page cache with the read data.
    var first: ?*Page = null;
    for (0..count) |i| {
        const base = i * page_size;
        if (base >= n) break;
        const len = @min(page_size, n - base);

        const page = find(inode, index + i) orelse try newPage(inode, index + i);
        @memcpy(page.data[0..len], scratch[base..][0..len]);
        @memset(page.data[len..], 0);
        page.len = len;
        touch(page);

        if (i == 0) first = page;
    }

    return first orelse Error.IoError;
}

/// Number of bytes that the page at `index` has when the file is `size` bytes.
fn expectedLen(size: usize, index: usize) usize {
    return @min(page_size, size - index * page_size);
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
    @memset(page.data, 0);

    page.next = bucket.*;
    bucket.* = page;

    inode.cache.pages.prepend(page);
    lru.prepend(page);

    return page;
}

/// Get an unused page, evicting the least recently used one if necessary.
fn takePage() Error!*Page {
    // No free list, and no available pages to allocate.
    if (free_list == null and num_pages >= max_pages) {
        stats.evictions += 1;
        remove(lru.last.?);
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

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const InlineDoublyLinkedList = common.typing.InlineDoublyLinkedList;
const urd = @import("urthr");
const fs = urd.fs;
const Error = fs.Error;
const File = fs.File;
const Inode = fs.Inode;
const Mutex = urd.sync.Mutex;
const uaccess = urd.uaccess;
