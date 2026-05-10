//! Process and thread module.

pub const loader = @import("task/loader.zig");
pub const thread = @import("task/thread.zig");
pub const Vmm = @import("task/Vmm.zig");

/// The number of pages allocated for user stack.
const num_stack_pages = 5;
/// Base address of the user stack.
const stack_base = 0x7FFF_FF00_0000;

/// Enter userland by loading the specified executable.
///
/// This function does not return on success.
pub fn enterUser(filename: []const u8) !noreturn {
    const current = sched.getCurrent();
    const allocator = urd.mem.getGeneralAllocator();

    // Initialize stdout.
    const console = try urd.fs.open("/dev/console", allocator);
    defer console.unref();
    _ = try current.fs.fdtbl.set(1, console);
    _ = try current.fs.fdtbl.set(2, console);

    // Load the executable.
    const ldr_info = try loader.load(current, filename);
    current.vmm.brk = ldr_info.brk;

    // Prepare user stack.
    const stack = try current.vmm.map(
        stack_base,
        num_stack_pages * urd.mem.page_size,
        .rw,
    );
    @memset(stack, 0);

    // Construct stack content.
    var scon = StackCreator.init(
        stack,
        stack_base,
        allocator,
    );
    // Arguments.
    {
        try scon.appendArgv(filename);
    }
    // Environment variables.
    {}
    // Auxiliary vectors.
    {
        // AT_RANDOM.
        var random: [16]u8 = undefined;
        urd.rng.getRandom(&random);
        const handle = try scon.appendOpaque(&random);
        try scon.appendAux(.new(.random, @intFromEnum(handle)));

        // AT_PAGESZ.
        try scon.appendAux(.new(.pagesz, urd.mem.page_size));
    }

    const usp = try scon.finalize();

    // Enter userland.
    arch.thread.enterUserland(ldr_info.entry, usp);
}

/// Exit the current process with the given exit code.
pub fn exit(code: i32) noreturn {
    log.debug("Process exiting with code {d}", .{code});

    log.err("not implemented: task.exit", .{});
    urd.eol(0);
}

/// Constructor for user stack.
const StackCreator = struct {
    const Self = @This();

    /// Environment variables.
    envs: std.array_list.Aligned([]const u8, null) = .empty,
    /// Command-line arguments.
    args: std.array_list.Aligned([]const u8, null) = .empty,
    /// Auxiliary vectors.
    auxs: std.array_list.Aligned(AuxVector, null) = .empty,
    /// Opaque data.
    opq: std.array_list.Aligned([]const u8, null) = .empty,

    /// Top of the stack in kernel address space.
    top: usize,
    /// Current top of the stack.
    sp: usize,
    /// Size of the stack in bytes.
    size: usize,
    /// User address of top of the stack.
    usp: usize,

    allocator: Allocator,

    /// End mark for envp and argv.
    const endmark: usize = 0;
    /// Stack alignment in bytes.
    const alignment = 16;

    /// Handle to describe opaque data.
    const OpaqueHandle = enum(u64) { _ };

    pub fn init(stack: []const u8, usp: usize, allocator: Allocator) Self {
        return .{
            .top = @intFromPtr(stack.ptr),
            .sp = @intFromPtr(stack.ptr) + stack.len,
            .size = stack.len,
            .usp = usp,
            .allocator = allocator,
        };
    }

    /// Append an argument to the stack.
    pub fn appendArgv(self: *Self, argv: []const u8) !void {
        try self.args.append(self.allocator, argv);
    }

    /// Append an environment variable to the stack.
    pub fn appendEnv(self: *Self, env: []const u8) !void {
        try self.envs.append(self.allocator, env);
    }

    /// Append an auxiliary vector to the stack.
    pub fn appendAux(self: *Self, auxv: AuxVector) !void {
        try self.auxs.append(self.allocator, auxv);
    }

    /// Append an opaque data to the stack.
    pub fn appendOpaque(self: *Self, data: []const u8) !OpaqueHandle {
        const handle: OpaqueHandle = @enumFromInt(self.opq.items.len);
        const dup = try self.allocator.dupe(u8, data);
        try self.opq.append(self.allocator, dup);
        return handle;
    }

    /// Finalize the stack.
    ///
    /// Returns the user pointer to the top of the stack.
    pub fn finalize(self: *Self) !usize {
        try self.appendAux(.new(.terminator, 0));

        var envps = try self.allocator.alloc(usize, self.envs.items.len);
        defer self.allocator.free(envps);
        var argvs = try self.allocator.alloc(usize, self.args.items.len);
        defer self.allocator.free(argvs);
        var opqs = try self.allocator.alloc(usize, self.opq.items.len);
        defer self.allocator.free(opqs);

        // Place opaque data.
        for (0..self.opq.items.len) |i| {
            const ri = self.opq.items.len - (i + 1);
            const opq = self.opq.items[ri];
            const s = self.extend(opq.len);
            @memcpy(s, opq);
            opqs[ri] = self.toUserPtr(@intFromPtr(s.ptr));
        }

        // Place data of environment variables.
        for (0..self.envs.items.len) |i| {
            const env = self.envs.items[self.envs.items.len - (i + 1)];
            const s = self.extend(env.len + 1);
            @memcpy(s[0..env.len], env);
            s[env.len] = 0;
            envps[i] = self.toUserPtr(@intFromPtr(s.ptr));
        }

        // Place data of arguments.
        for (0..self.args.items.len) |i| {
            const arg = self.args.items[self.args.items.len - (i + 1)];
            const s = self.extend(arg.len + 1);
            @memcpy(s[0..arg.len], arg);
            s[arg.len] = 0;
            argvs[i] = self.toUserPtr(@intFromPtr(s.ptr));
        }

        // Ensure alignment.
        self.makeAlign(alignment);

        // Place auxiliary vectors.
        for (0..self.auxs.items.len) |i| {
            const auxv = self.auxs.items[self.auxs.items.len - (i + 1)];
            switch (auxv.auxv_type) {
                .random => self.extendAs(AuxVector).* = .new(.random, opqs[auxv.value]),
                else => self.extendAs(AuxVector).* = auxv,
            }
        }

        // Construct envp.
        self.extendAs(@TypeOf(endmark)).* = endmark;
        for (envps) |envp| {
            self.extendAs(usize).* = envp;
        }
        // Construct argv.
        self.extendAs(@TypeOf(endmark)).* = endmark;
        for (argvs) |argv| {
            self.extendAs(usize).* = argv;
        }

        // Push argc.
        self.extendAs(usize).* = self.args.items.len;

        // Deinit resources.
        self.args.deinit(self.allocator);
        self.envs.deinit(self.allocator);
        self.auxs.deinit(self.allocator);
        for (self.opq.items) |data| {
            self.allocator.free(data);
        }
        self.opq.deinit(self.allocator);

        return self.toUserPtr(self.sp);
    }

    /// Extend the stack by the given size and return the extended region.
    fn extend(self: *Self, size: usize) []u8 {
        self.sp -= size;
        self.size += size;
        return @as([*]u8, @ptrFromInt(self.sp))[0..size];
    }

    /// Extend the stack for the given type and return a pointer to the extended region.
    fn extendAs(self: *Self, comptime T: type) *T {
        const size = @sizeOf(T);
        const slice = self.extend(size);
        return @ptrCast(@alignCast(slice.ptr));
    }

    /// Convert the given stack pointer to a user pointer.
    fn toUserPtr(self: *Self, ptr: usize) usize {
        return self.usp + (ptr - self.top);
    }

    /// Ensure the stack pointer is aligned to the given alignment.
    fn makeAlign(self: *Self, algn: usize) void {
        for (0..self.sp % algn) |_| {
            self.extend(1)[0] = 0;
        }
    }
};

/// Auxiliary vector for passing information from Urthr to the user process.
pub const AuxVector = extern struct {
    /// Type of the entry.
    auxv_type: AuxvType,
    /// Value of the entry.
    value: u64,

    const AuxvType = enum(u64) {
        /// The last entry in the array.
        terminator = 0,
        /// Should be ignored.
        ignore = 1,
        /// File descriptor of program.
        execfd = 2,
        /// Program headers for program.
        phdr = 3,
        /// Size of program header entry.
        phent = 4,
        /// Number of program headers.
        phnum = 5,
        /// System page size.
        pagesz = 6,
        /// Base address of interpreter.
        base = 7,
        /// Flags.
        flags = 8,
        /// Entry point of program.
        entry = 9,
        /// Program is not ELF.
        notelf = 10,
        /// Real UID.
        uid = 11,
        /// Effective UID.
        euid = 12,
        /// Real GID.
        gid = 13,
        /// Effective GID.
        egid = 14,
        /// String identifying platform.
        platform = 15,
        /// Machine dependent hints about process capabilities.
        hwcap = 16,
        /// Frequency of times()
        clktck = 17,
        /// Used FPU control word.
        fpucw = 18,
        /// Data cache block size.
        dcachebsize = 19,
        /// Instruction cache block size.
        icachebsize = 20,
        /// Unified cache block size.
        ucachebsize = 21,

        random = 25,
    };

    /// Construct an auxiliary vector using immediate value.
    pub fn new(atype: AuxvType, value: u64) AuxVector {
        return .{
            .auxv_type = atype,
            .value = value,
        };
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.task);
const Allocator = std.mem.Allocator;
const arch = @import("arch").impl;
const urd = @import("urthr");
const sched = urd.sched;
