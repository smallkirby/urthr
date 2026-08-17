//! Process credential.

const Self = @This();

/// Real user ID.
uid: u32 = 0,
/// Real group ID.
gid: u32 = 0,
/// Effective user ID.
euid: u32 = 0,
/// Effective group ID.
egid: u32 = 0,
/// Saved user ID.
suid: u32 = 0,
/// Saved group ID.
sgid: u32 = 0,

/// Whether this credential has root privilege.
pub fn isPrivileged(self: Self) bool {
    return self.euid == 0;
}
