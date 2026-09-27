//! Directory entry.
//!
//! Associates an inode with its file name to represent the hierarchical structure of the tree.

const Self = @This();
const Dentry = Self;
const Error = fs.Error;

/// File name.
name: []const u8,
/// Inode associated with this dentry.
inode: *Inode,
/// Parent dentry. `null` if this is the root dentry.
parent: ?*Dentry,
/// If this dentry is a mount point, the mount attached to this dentry.
mount: ?*Mount = null,
/// Reference count.
refcnt: std.atomic.Value(usize) = .init(1),
/// Memory allocator.
allocator: Allocator,

/// Create a new dentry with the given name and inode.
///
/// The returned dentry takes ownership of the inode reference.
/// Caller owns the returned dentry.
pub fn create(name: []const u8, inode: *Inode, parent: ?*Dentry, allocator: Allocator) Error!*Dentry {
    const dentry = try allocator.create(Dentry);
    errdefer allocator.destroy(dentry);

    dentry.* = .{
        .name = try allocator.dupe(u8, name),
        .inode = inode,
        .parent = parent,
        .allocator = allocator,
    };

    if (parent) |p| p.ref();
    return dentry;
}

/// Increment the reference count of this dentry.
pub fn ref(self: *Self) void {
    _ = self.refcnt.fetchAdd(1, .acq_rel);
}

/// Decrement the reference count of this dentry.
///
/// If the count reaches zero, the dentry is deallocated and its resources are released.
pub fn unref(self: *Self) void {
    const prev = self.refcnt.fetchSub(1, .acq_rel);
    rtt.expect(prev != 0);
    if (prev == 1) {
        const parent = self.parent;
        self.inode.unref();
        self.allocator.free(self.name);
        self.allocator.destroy(self);
        if (parent) |p| p.unref();
    }
}

// =============================================================
// Dentry cache
// =============================================================

pub const Cache = struct {
    /// Hash map that uses parent dentry and name as key.
    const DcacheMap = std.HashMap(Key, *Dentry, Context, 80);

    /// Key of the hash map.
    const Key = struct {
        /// Parent dentry this key belongs to.
        parent: ?*Dentry,
        /// Name of the dentry.
        name: []const u8,
        /// Whether `name` is case-insensitive.
        case_insensitive: bool,
    };

    const Context = struct {
        pub fn hash(_: Context, key: Key) u64 {
            // Hash parent dentry.
            const dentry_hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&key.parent));
            // Hash name.
            var name_hasher = std.hash.Wyhash.init(0);
            if (key.case_insensitive) {
                for (key.name) |c| {
                    const lc = std.ascii.toLower(c);
                    name_hasher.update(std.mem.asBytes(&lc));
                }
            } else {
                name_hasher.update(key.name);
            }
            // Combine the hashes of the parent dentry and the name.
            const combined = bits.concat(u128, dentry_hash, name_hasher.final());
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&combined));
        }
        pub fn eql(_: Context, a: Key, b: Key) bool {
            if (a.parent != b.parent) return false;
            return if (a.case_insensitive or b.case_insensitive)
                std.ascii.eqlIgnoreCase(a.name, b.name)
            else
                std.mem.eql(u8, a.name, b.name);
        }
    };

    /// Map instance.
    _map: DcacheMap,
    /// Spin lock to protect the map.
    _lock: SpinLock = .{},

    /// Create a new dentry store.
    pub fn new(allocator: Allocator) Cache {
        return .{
            ._map = DcacheMap.init(allocator),
        };
    }

    /// Lookup a dentry by parent and name.
    ///
    /// Caller must call `unref()` for the returned dentry after use.
    pub fn lookup(self: *Cache, parent: ?*Dentry, name: []const u8, case_insensitive: bool) ?*Dentry {
        self._lock.lock();
        defer self._lock.unlock();

        const result = self._map.get(.{
            .parent = parent,
            .name = name,
            .case_insensitive = case_insensitive,
        }) orelse return null;

        result.ref();

        return result;
    }

    /// Remove a dentry from the cache, releasing the reference to it.
    ///
    /// Caller must ensure that the dentry is cached.
    pub fn remove(self: *Cache, parent: ?*Dentry, name: []const u8, case_insensitive: bool) void {
        // Release the reference outside the lock.
        const removed = blk: {
            self._lock.lock();
            defer self._lock.unlock();

            break :blk self._map.fetchRemove(.{
                .parent = parent,
                .name = name,
                .case_insensitive = case_insensitive,
            });
        };

        if (removed) |kv| {
            kv.value.unref();
        } else {
            rtt.expect(false);
        }
    }

    /// Insert the dentry to the cache.
    ///
    /// Returns the cached dentry.
    /// If a dentry with the same key is already cached, it is kept and `entry` is not inserted.
    /// Caller must call `unref()` for the returned dentry after use.
    pub fn insert(self: *Cache, entry: *Dentry, case_insensitive: bool) *Dentry {
        self._lock.lock();
        defer self._lock.unlock();

        const result = self._map.getOrPut(.{
            .parent = entry.parent,
            .name = entry.name,
            .case_insensitive = case_insensitive,
        }) catch unreachable;
        if (!result.found_existing) {
            entry.ref();
            result.value_ptr.* = entry;
        }

        const cached = result.value_ptr.*;
        cached.ref();

        return cached;
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const bits = common.bits;
const rtt = common.rtt;
const urd = @import("urthr");
const SpinLock = urd.sync.SpinLock;
const fs = urd.fs;
const Inode = @import("Inode.zig");
const File = @import("File.zig");
const Path = fs.Path;
const Mount = @import("Mount.zig");
