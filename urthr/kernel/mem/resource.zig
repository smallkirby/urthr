//! This module provides a map of physical memory resources in the system.

pub const ResourceError = error{
    /// Resource not available.
    NotAvailable,
    /// Invalid argument.
    InvalidArgument,
    /// Memory allocation failed.
    OutOfMemory,
};

const ResourceList = InlineDoublyLinkedList(MemoryResource, "list_head");

/// List of memory resources.
///
/// This list must be sorted by the start address of the memory resources.
var resources: ResourceList = .{};

/// Memory resource descriptor.
///
/// Descriptors can have children to represent hierarchical memory resources.
pub const MemoryResource = struct {
    const Self = @This();

    /// Readable name of the memory resource.
    name: ?[]const u8,
    /// Start address of the memory resource.
    start: usize,
    /// Size in bytes of the memory resource.
    size: usize,

    /// Memory this resource belongs to.
    parent: ?*MemoryResource = null,
    /// Children of this memory resource.
    children: ResourceList = .{},
    /// List head.
    list_head: ResourceList.Head = .{},

    /// Add a child memory resource to this resource.
    pub fn appendChild(
        self: *Self,
        name: []const u8,
        start: usize,
        size: usize,
        allocator: Allocator,
    ) ResourceError!*MemoryResource {
        if (start < self.start or start + size > self.start + self.size) {
            return ResourceError.InvalidArgument;
        }
        const end = start + size;

        // Check for overlapping with existing children.
        var current = self.children.first;
        while (current) |res| : (current = res.list_head.next) {
            if (res.start < end and start < res.start + res.size) {
                return ResourceError.NotAvailable;
            }
        }

        // Create the child resource.
        const child = try allocator.create(MemoryResource);
        child.* = .{
            .name = name,
            .start = start,
            .size = size,
            .parent = self,
            .children = .{},
        };
        self.children.insertSorted(child, compareResources);

        return child;
    }
};

/// Comparator function for `MemoryResource`.
fn compareResources(a: *MemoryResource, b: *MemoryResource) std.math.Order {
    if (a.start < b.start) return .lt;
    if (a.start > b.start) return .gt;
    return .eq;
}

/// Reserve a physical memory range as a resource.
pub fn requestResource(
    name: []const u8,
    start: usize,
    size: usize,
    allocator: Allocator,
) ResourceError!*MemoryResource {
    if (start % mem.size_4kib != 0) {
        return ResourceError.InvalidArgument;
    }
    if (size % mem.size_4kib != 0) {
        return ResourceError.InvalidArgument;
    }
    const end = start + size;

    // Check for overlapping with existing resources.
    var current = resources.first;
    while (current) |res| : (current = res.list_head.next) {
        if (res.start < end and start < res.start + res.size) {
            return ResourceError.NotAvailable;
        }
    }

    // Create the resource.
    const resource = try allocator.create(MemoryResource);
    resource.* = .{
        .name = name,
        .start = start,
        .size = size,
    };
    resources.insertSorted(resource, compareResources);

    rttResourcesSorted();

    return resource;
}

// =============================================================
// Tests
// =============================================================

fn rttResourcesSorted() void {
    if (!urd.enable_rtt) return;

    const S = struct {
        fn f(list: ResourceList) void {
            rtt.expect(list.isSorted(compareResources));

            var current = list.first;
            while (current) |res| : (current = res.list_head.next) {
                f(res.children);
            }
        }
    };

    S.f(resources);
}

// =============================================================
// Debug
// =============================================================

/// Print all resources to the debug log.
pub fn debugPrintResources(logger: anytype) void {
    var current = resources.first;
    while (current) |res| : (current = res.list_head.next) {
        logger("{X:0>12}-{X:0>12} : {s}", .{
            res.start,
            res.start + res.size,
            res.name orelse "",
        });

        var child_current = res.children.first;
        while (child_current) |child| : (child_current = child.list_head.next) {
            logger("\t{X:0>12}-{X:0>12} : {s}", .{
                child.start,
                child.start + child.size,
                child.name orelse "",
            });
        }
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

const urd = @import("urthr");
const mem = urd.mem;
const rtt = urd.rtt;
const common = @import("common");
const units = common.units;
const InlineDoublyLinkedList = common.typing.InlineDoublyLinkedList;
