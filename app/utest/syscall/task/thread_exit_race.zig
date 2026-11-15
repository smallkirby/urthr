const iterations = 100;
const worker_status = 0;

const S = struct {
    var go = std.atomic.Value(u32).init(0);

    fn worker(status: usize) callconv(.c) u8 {
        while (go.load(.acquire) == 0) {}
        linux.exit(@intCast(status));
        unreachable;
    }
};

// Must not release shared resources twice when threads exit concurrently.
test "leader and the last thread exit at the same time" {
    for (0..iterations) |_| {
        try utest.expectRunChild(worker_status << 8, struct {
            pub fn lambda(_: usize) noreturn {
                _ = utest.task.spawnThread(S.worker, worker_status) catch {
                    linux.exit_group(2);
                };

                S.go.store(1, .release);
                linux.exit(0);
            }
        });
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const linux = std.os.linux;
const utest = @import("utest");
