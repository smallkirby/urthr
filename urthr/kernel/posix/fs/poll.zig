// =============================================================
// poll

/// syscall: poll
pub fn sysPoll(fds: ?[*]align(1) PollFd, nfds: usize, timeout: i32) ReturnType {
    const ns: ?u64 = if (timeout < 0)
        null
    else
        @as(u64, @intCast(timeout)) * std.time.ns_per_ms;

    return pollImpl(fds, nfds, ns);
}

/// syscall: ppoll
pub fn sysPpoll(
    fds: ?[*]align(1) PollFd,
    nfds: usize,
    tmop: ?*align(1) const Timespec,
    _: ?*const anyopaque, // TODO: unused
    _: usize, // TODO: unused
) ReturnType {
    var ns: ?u64 = null;
    if (tmop) |t| {
        const ts = uaccess.getUser(Timespec, t) catch return .err(.fault);
        ns = ts.toNs() orelse return .err(.inval);
    }

    return pollImpl(fds, nfds, ns);
}

/// Shared implementation of poll.
fn pollImpl(fds: ?[*]align(1) PollFd, nfds: usize, ns: ?u64) ReturnType {
    if (nfds >= Event.max_multiwait) {
        return .err(.inval);
    }
    if (nfds != 0 and fds == null) {
        return .err(.fault);
    }

    const kfds = mem.bin.alloc(PollFd, nfds) catch return .err(.nomem);
    defer mem.bin.free(kfds);
    if (nfds > 0) urd.uaccess.copySliceFromUser(
        PollFd,
        kfds,
        fds.?,
    ) catch return .err(.fault);

    const done = pollFiles(kfds, ns);

    if (nfds > 0) uaccess.copySliceToUser(
        PollFd,
        fds.?,
        kfds,
    ) catch return .err(.fault);

    return .success(@intCast(done));
}

/// POSIX-compliant pollfd structure.
const PollFd = extern struct {
    /// File descriptor.
    fd: i32,
    /// Requested events.
    events: PollEvents,
    /// Returned events.
    revents: PollEvents,
};

/// POSIX-compliant event type that can be polled for.
const PollEvents = packed struct(u16) {
    /// There is data to read.
    in: bool,
    /// There is urgent data to read.
    pri: bool,
    /// Writing now will not block.
    out: bool,

    // =============================================================
    // Always implicitly polled for.
    // Users should not include these in `events`, but `revents` may contain these values.

    /// Error condition.
    err: bool,
    /// Hung up.
    hup: bool,
    /// Invalid polling request.
    nval: bool,

    /// Reserved.
    _reserved: u10 = 0,

    const empty = std.mem.zeroes(PollEvents);

    /// Bitwise AND of two PollEvents.
    fn eand(self: PollEvents, other: PollEvents) PollEvents {
        return @bitCast(@as(u16, @bitCast(self)) & @as(u16, @bitCast(other)));
    }
};

// =============================================================
// select

const UserFdSet = ?*align(1) FdSet;

/// syscall: select
pub fn sysSelect(
    nfds: usize,
    readfds: UserFdSet,
    writefds: UserFdSet,
    exceptfds: UserFdSet,
    timeout: ?*align(1) Timeval,
) ReturnType {
    var ns: ?u64 = null;
    if (timeout) |t| {
        const tv = uaccess.getUser(Timeval, t) catch return .err(.fault);
        ns = tv.toNs() orelse return .err(.inval);
    }

    return selectTimed(
        Timeval,
        nfds,
        readfds,
        writefds,
        exceptfds,
        timeout,
        ns,
    );
}

/// syscall: pselect6
///
/// - `sigmask`: TODO: Unused.
pub fn sysPselect6(
    nfds: usize,
    readfds: UserFdSet,
    writefds: UserFdSet,
    exceptfds: UserFdSet,
    timeout: ?*align(1) Timespec,
    _: ?*const anyopaque,
) ReturnType {
    var ns: ?u64 = null;
    if (timeout) |t| {
        const ts = uaccess.getUser(Timespec, t) catch return .err(.fault);
        ns = ts.toNs() orelse return .err(.inval);
    }

    return selectTimed(
        Timespec,
        nfds,
        readfds,
        writefds,
        exceptfds,
        timeout,
        ns,
    );
}

/// Run select and write the remaining time back to the user `timeout` on success.
fn selectTimed(
    comptime Time: type,
    nfds: usize,
    readfds: UserFdSet,
    writefds: UserFdSet,
    exceptfds: UserFdSet,
    timeout: ?*align(1) Time,
    ns: ?u64,
) ReturnType {
    const start = urd.time.getCurrentTimestamp();
    const ret = selectImpl(
        nfds,
        readfds,
        writefds,
        exceptfds,
        ns,
    );

    if (!ret.isSuccess()) return ret;

    const t = timeout orelse return ret;
    uaccess.putUser(
        Time,
        t,
        .fromNs(remainingNs(ns.?, start)),
    ) catch return .err(.fault);

    return ret;
}

/// Get the remaining time of the timeout that started at `start`.
fn remainingNs(ns: u64, start: u64) u64 {
    return ns -| (urd.time.getCurrentTimestamp() - start);
}

/// Shared implementation of select.
fn selectImpl(
    nfds: usize,
    readfds: UserFdSet,
    writefds: UserFdSet,
    exceptfds: UserFdSet,
    ns: ?u64,
) ReturnType {
    if (nfds > FdSet.max_fds) {
        return .err(.inval);
    }

    // Copy user fdsets into kernel.
    const nwords = FdSet.numWords(nfds);
    var rset: FdSet = .{};
    var wset: FdSet = .{};
    var eset: FdSet = .{};
    inline for (.{
        .{ &rset, readfds },
        .{ &wset, writefds },
        .{ &eset, exceptfds },
    }) |pair| {
        if (pair[1]) |user| uaccess.copySliceFromUser(
            u64,
            pair[0].bits[0..nwords],
            user,
        ) catch return .err(.fault);
    }

    // Build the poll list from the fds in the sets.
    var kfds: [Event.max_multiwait - 1]PollFd = undefined;
    var n: usize = 0;
    for (0..nfds) |fd| {
        const events = std.mem.zeroInit(PollEvents, .{
            .in = rset.isSet(fd),
            .out = wset.isSet(fd),
            .pri = eset.isSet(fd),
        });
        if (events == PollEvents.empty) continue;
        if (n == kfds.len) return .err(.inval);

        kfds[n] = .{
            .fd = @intCast(fd),
            .events = events,
            .revents = .empty,
        };
        n += 1;
    }

    // Do polling.
    _ = pollFiles(kfds[0..n], ns);

    // Collect the results.
    rset = .{};
    wset = .{};
    eset = .{};
    var count: i64 = 0;
    for (kfds[0..n]) |pfd| {
        if (pfd.revents.nval) return .err(.badf);

        const fd: usize = @intCast(pfd.fd);
        inline for (.{
            .{ &rset, pfd.revents.in },
            .{ &wset, pfd.revents.out },
            .{ &eset, pfd.revents.pri },
        }) |pair| {
            if (pair[1]) {
                pair[0].set(fd);
                count += 1;
            }
        }
    }

    // Copy the fdsets back to user space.
    inline for (.{
        .{ &rset, readfds },
        .{ &wset, writefds },
        .{ &eset, exceptfds },
    }) |pair| {
        if (pair[1]) |user| uaccess.copySliceToUser(
            u64,
            user,
            pair[0].bits[0..nwords],
        ) catch return .err(.fault);
    }

    return .success(count);
}

/// POSIX-compliant fd_set structure.
const FdSet = extern struct {
    const Word = u64;

    bits: [max_fds / @bitSizeOf(Word)]Word = @splat(0),

    /// Maximum number of file descriptors.
    const max_fds = 1024;

    /// Number of words to hold the given number of fds.
    fn numWords(nfds: usize) usize {
        return @divCeil(nfds, @bitSizeOf(Word));
    }

    /// Check if the given file descriptor is set.
    fn isSet(self: *const FdSet, fd: usize) bool {
        return self.bits[fd / @bitSizeOf(Word)] >> @intCast(fd % @bitSizeOf(Word)) & 1 != 0;
    }

    /// Set the given file descriptor.
    fn set(self: *FdSet, fd: usize) void {
        self.bits[fd / @bitSizeOf(Word)] |= @as(Word, 1) << @intCast(fd % @bitSizeOf(Word));
    }
};

// =============================================================
// Shared implementation.

/// Poll the files until at least one is ready or the timeout expires.
///
/// Returns the number of ready files.
fn pollFiles(kfds: []PollFd, ns: ?u64) usize {
    // Calculate deadline for blocking.
    const deadline_ns = if (ns) |d|
        urd.time.getCurrentTimestamp() +| d
    else
        null;

    return while (true) {
        var n_ready: usize = 0;
        var wait_events: [Event.max_multiwait - 1]*Event = undefined;
        var n_events: usize = 0;

        // Check if any of the file descriptors are ready.
        for (kfds) |*pfd| {
            pfd.revents = .empty;

            // Ignore negative descriptors.
            if (pfd.fd < 0) continue;

            // Poll the file readiness.
            const file = getFile(pfd.fd) orelse {
                pfd.revents.nval = true;
                n_ready += 1;
                continue;
            };
            defer file.unref();
            const result = file.poll() catch {
                pfd.revents.err = true;
                n_ready += 1;
                continue;
            };
            const ready = std.mem.zeroInit(PollEvents, .{
                .in = result.events.in,
                .pri = result.events.urgent,
                .out = result.events.out,
            });
            pfd.revents = pfd.events.eand(ready);

            if (pfd.revents != PollEvents.empty) {
                n_ready += 1;
            } else if (result.wait) |ev| {
                wait_events[n_events] = ev;
                n_events += 1;
            }
        }

        // If at least one event is ready, return.
        if (n_ready > 0) {
            break n_ready;
        }

        // If it already reached the deadline, return.
        if (deadline_ns) |dl| {
            if (urd.time.getCurrentTimestamp() >= dl) break @as(usize, 0);
        }

        if (n_events > 0 or deadline_ns != null)
            _ = Event.waitAny(
                wait_events[0..n_events],
                deadline_ns,
            )
        else
            sched.reschedule();
    };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const mem = urd.mem;
const sched = urd.sched;
const uaccess = urd.uaccess;
const Event = urd.sync.Event;
const ReturnType = urd.syscall.ReturnType;
const Timespec = urd.posix.Timespec;
const Timeval = urd.posix.Timeval;

const helper = @import("helper.zig");
const getFile = helper.getFile;
