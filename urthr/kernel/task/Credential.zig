//! Process credential.

const Self = @This();

/// Maximum number of supplementary group IDs.
pub const ngroups_max = 32;

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
/// Supplementary group IDs.
groups: [ngroups_max]u32 = undefined,
/// Number of valid entries in `groups`.
ngroups: u32 = 0,

/// Whether this credential has root privilege.
pub fn isPrivileged(self: Self) bool {
    return self.euid == 0;
}
