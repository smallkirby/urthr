pub const OpenFlags = switch (builtin.cpu.arch) {
    .x86_64 => packed struct(i32) {
        /// Write-only.
        wo: bool = false,
        /// Read and write.
        rdwr: bool = false,
        /// Reserved.
        _2: bool = false,
        /// Reserved.
        _3: u3 = 0,
        /// Create file if it does not exist.
        creat: bool = false,
        /// Error if O_CREAT and the file exists.
        excl: bool = false,
        /// Even if the path refers to TTY, do not open it as a controlling TTY device.
        noctty: bool = false,
        /// Truncate file to zero length if it already exists.
        trunc: bool = false,
        /// Append mode.
        append: bool = false,
        /// Nonblocking mode if possible.
        nonblock: bool = false,
        /// Reserved.
        _12: u4 = 0,
        /// Fail unless the path resolves to a directory.
        directory: bool = false,
        /// Reserved.
        _17: u2 = 0,
        /// Enable close-on-exec flag.
        cloexec: bool = false,
        /// Reserved.
        _20: u12 = 0,

        /// Check if the current flags fit within the allowed flags.
        pub fn isFit(self: OpenFlags, allowed: OpenFlags) bool {
            return @backingInt(self) & ~@backingInt(allowed) == 0;
        }
    },
    else => packed struct(i32) {
        /// Write-only.
        wo: bool = false,
        /// Read and write.
        rdwr: bool = false,
        /// Reserved.
        _2: bool = false,
        /// Reserved.
        _3: u3 = 0,
        /// Create file if it does not exist.
        creat: bool = false,
        /// Error if O_CREAT and the file exists.
        excl: bool = false,
        /// Even if the path refers to TTY, do not open it as a controlling TTY device.
        noctty: bool = false,
        /// Truncate file to zero length if it already exists.
        trunc: bool = false,
        /// Append mode.
        append: bool = false,
        /// Nonblocking mode if possible.
        nonblock: bool = false,
        /// Reserved.
        _12: u2 = 0,
        /// Fail unless the path resolves to a directory.
        directory: bool = false,
        /// Reserved.
        _15: u4 = 0,
        /// Enable close-on-exec flag.
        cloexec: bool = false,
        /// Reserved.
        _20: u12 = 0,

        /// Check if the current flags fit within the allowed flags.
        pub fn isFit(self: OpenFlags, allowed: OpenFlags) bool {
            return @backingInt(self) & ~@backingInt(allowed) == 0;
        }
    },
};

/// Flags shared by `at`-suffixed syscalls.
pub const AtFlags = packed struct(i32) {
    /// Reserved.
    _0: u8 = 0,
    /// If pathname is a symbolic link, do not deference it.
    symlink_nofollow: bool = false,
    /// Remove the directory entry as a directory.
    removedir: bool = false,
    /// If pathname is a symbolic link, dereference it.
    symlink_follow: bool = false,
    /// Do not automount the terminal component of pathname.
    no_automount: bool = false,
    /// If pathname is empty, operate on dirfd itself.
    empty_path: bool = false,
    /// Reserved.
    _13: u19 = 0,

    pub fn isFit(self: AtFlags, allowed: AtFlags) bool {
        return @backingInt(self) & ~@backingInt(allowed) == 0;
    }
};

/// File information including file type, access permission, and other special bits.
pub const Mode = packed struct(u32) {
    /// Access permission for others.
    other: Permission = .rwx,
    /// Access permission for a group.
    group: Permission = .rwx,
    /// Access permission for a user.
    user: Permission = .rwx,
    /// Special flags.
    flags: Flags = .none,
    /// File type.
    type: FileType,
    /// Reserved.
    _reserved: u16 = 0,

    const Flags = packed struct(u3) {
        /// Sticky bit.
        sticky: bool,
        /// Set Group ID.
        sgid: bool,
        /// Set User ID.
        suid: bool,

        pub const none = Flags{ .sticky = false, .sgid = false, .suid = false };

        fn from(f: fs.FileMode.Flags) Flags {
            return .{
                .sticky = f.sticky,
                .sgid = f.sgid,
                .suid = f.suid,
            };
        }

        fn to(self: Flags) fs.FileMode.Flags {
            return .{
                .sticky = self.sticky,
                .sgid = self.sgid,
                .suid = self.suid,
            };
        }
    };

    pub fn from(file: *const fs.File) Mode {
        const mode = file.getMode();
        return .{
            .type = .from(file.getType()),
            .other = .from(mode.other),
            .group = .from(mode.group),
            .user = .from(mode.user),
            .flags = .from(mode.flags),
        };
    }

    /// Convert to fs file mode.
    pub fn to(self: Mode) fs.FileMode {
        return .{
            .other = self.other.to(),
            .group = self.group.to(),
            .user = self.user.to(),
            .flags = self.flags.to(),
        };
    }

    /// Convert from fs file mode.
    pub fn fromFileMode(mode: fs.FileMode) Mode {
        return .{
            .other = .from(mode.other),
            .group = .from(mode.group),
            .user = .from(mode.user),
            .type = @fromBackingInt(@intCast(0)),
            .flags = .from(mode.flags),
        };
    }
};

/// Access permission for a single target.
const Permission = packed struct(u3) {
    read: bool,
    write: bool,
    exec: bool,

    const ro = Permission{ .read = true, .write = false, .exec = false };
    const rw = Permission{ .read = true, .write = true, .exec = false };
    const rx = Permission{ .read = true, .write = false, .exec = true };
    const rwx = Permission{ .read = true, .write = true, .exec = true };
    const none = Permission{ .read = false, .write = false, .exec = false };

    fn from(p: fs.Permission) Permission {
        return .{
            .read = p.read,
            .write = p.write,
            .exec = p.exec,
        };
    }

    fn to(self: Permission) fs.Permission {
        return .{
            .read = self.read,
            .write = self.write,
            .exec = self.exec,
        };
    }
};

/// File type.
pub const FileType = enum(u4) {
    /// Named pipe or FIFO.
    fifo = 1,
    /// Character special device.
    char = 2,
    /// Directory.
    dir = 4,
    /// Block special device.
    blk = 6,
    /// Regular file.
    regular = 8,
    /// Symbolic link.
    symlink = 10,
    /// Socket.
    socket = 12,

    _,

    /// Convert from Urthr FileType.
    pub fn from(ftype: fs.FileType) FileType {
        return switch (ftype) {
            .regular => .regular,
            .directory => .dir,
            .symlink => .symlink,
            .socket => .socket,
        };
    }
};

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const urd = @import("urthr");
const fs = urd.fs;
