//! POSIX compatibility layer for filesystem API.

pub const OpenFlags = abi.OpenFlags;

pub const sysOpenAt = open.sysOpenAt;
pub const sysOpen = open.sysOpen;
pub const sysDup = open.sysDup;
pub const sysDup2 = open.sysDup2;
pub const sysDup3 = open.sysDup3;
pub const sysPipe = open.sysPipe;
pub const sysPipe2 = open.sysPipe2;
pub const sysFadvise64 = open.sysFadvise64;
pub const sysClose = open.sysClose;

pub const sysLseek = rw.sysLseek;
pub const sysWrite = rw.sysWrite;
pub const sysPwrite64 = rw.sysPwrite64;
pub const sysWritev = rw.sysWritev;
pub const sysPwritev = rw.sysPwritev;
pub const sysFtruncate = rw.sysFtruncate;
pub const sysRead = rw.sysRead;
pub const sysPread64 = rw.sysPread64;
pub const sysReadv = rw.sysReadv;
pub const sysPreadv = rw.sysPreadv;
pub const sysSendfile = rw.sysSendfile;
pub const sysCopyFileRange = rw.sysCopyFileRange;

pub const sysSync = sync.sysSync;
pub const sysFsync = sync.sysFsync;
pub const sysFdataSync = sync.sysFdataSync;
pub const sysSyncFs = sync.sysSyncFs;

pub const sysFcntl = ctl.sysFcntl;
pub const sysIoctl = ctl.sysIoctl;
pub const sysFlock = ctl.sysFlock;

pub const sysFchmodAt = attr.sysFchmodAt;
pub const sysChmod = attr.sysChmod;
pub const sysFchmod = attr.sysFchmod;
pub const sysFchown = attr.sysFchown;
pub const sysFchownAt = attr.sysFchownAt;
pub const sysChown = attr.sysChown;
pub const sysLchown = attr.sysLchown;
pub const sysFaccessAt = attr.sysFaccessAt;
pub const sysAccess = attr.sysAccess;
pub const sysUtimensAt = attr.sysUtimensAt;
pub const sysUmask = attr.sysUmask;

pub const sysFstat = stat.sysFstat;
pub const sysNewFstatAt = stat.sysNewFstatAt;
pub const sysStat = stat.sysStat;
pub const sysLstat = stat.sysLstat;
pub const sysStatx = stat.sysStatx;

pub const sysMkdirAt = dir.sysMkdirAt;
pub const sysMkdir = dir.sysMkdir;
pub const sysGetDents64 = dir.sysGetDents64;
pub const sysChdir = dir.sysChdir;
pub const sysFchdir = dir.sysFchdir;
pub const sysGetCwd = dir.sysGetCwd;

pub const sysUnlinkAt = link.sysUnlinkAt;
pub const sysUnlink = link.sysUnlink;
pub const sysRmdir = link.sysRmdir;
pub const sysSymlinkAt = link.sysSymlinkAt;
pub const sysSymlink = link.sysSymlink;
pub const sysReadLinkAt = link.sysReadLinkAt;
pub const sysReadLink = link.sysReadLink;
pub const sysRenameAt = link.sysRenameAt;
pub const sysRename = link.sysRename;
pub const sysRenameAt2 = link.sysRenameAt2;

pub const sysMount = mount.sysMount;
pub const sysUmount2 = mount.sysUmount2;

pub const sysPoll = poll.sysPoll;
pub const sysPpoll = poll.sysPpoll;
pub const sysSelect = poll.sysSelect;
pub const sysPselect6 = poll.sysPselect6;

// =============================================================
// Imports
// =============================================================

const abi = @import("fs/abi.zig");
const open = @import("fs/open.zig");
const rw = @import("fs/rw.zig");
const sync = @import("fs/sync.zig");
const ctl = @import("fs/ctl.zig");
const attr = @import("fs/attr.zig");
const stat = @import("fs/stat.zig");
const dir = @import("fs/dir.zig");
const link = @import("fs/link.zig");
const mount = @import("fs/mount.zig");
const poll = @import("fs/poll.zig");
