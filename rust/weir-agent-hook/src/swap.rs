//! Putting a file in place without writing over what another writer put
//! there: exchanging two directory entries, and renaming onto a
//! path only while nothing is there.
//!
//! A restore writes each path by exchanging it with a file made in the
//! worktree's staging area, then looks at what came out. The exchange is
//! one step on macOS (`renameatx_np`) and Linux (`renameat2`), so an
//! editor's save lands either before it, and comes out to be put back, or
//! after it, and stays. Other systems, where only the tests run, get the
//! same result in three renames.
//!
//! Every path is relative to the worktree, and reached from it one
//! directory at a time without following a link: a directory swapped for
//! a link after the plan read it fails the write, rather than lead it out
//! of the worktree.

use std::io;
use std::path::{Component, Path};

/// Exchanges what `first` and `second` name under `root`. Both must
/// exist, and both still do after: a volume that renamed one over the
/// other instead fails here, though `check_volume` keeps writes off such a
/// volume first.
pub(crate) fn exchange(root: &Path, first: &Path, second: &Path) -> io::Result<()> {
    platform::exchange(root, first, second)?;
    let exists = |path: &Path| std::fs::symlink_metadata(root.join(path)).is_ok();
    if !exists(first) || !exists(second) {
        return Err(io::Error::other("the exchange did not keep both names"));
    }
    Ok(())
}

/// Renames `from` to `to` under `root` only while nothing is at `to`.
pub(crate) fn rename_new(root: &Path, from: &Path, to: &Path) -> io::Result<()> {
    platform::rename_new(root, from, to)
}

/// Makes the directories of `relative` under `root` that are missing,
/// none of them through a link.
pub(crate) fn make_parents(root: &Path, relative: &Path) -> io::Result<()> {
    platform::make_parents(root, relative)
}

/// Whether the volume of `path` exchanges two names and renames onto
/// nothing in one step. Asked of the volume, not tried: FAT says it
/// exchanges and overwrites.
pub(crate) fn can_exchange(path: &Path) -> bool {
    platform::can_exchange(path)
}

/// A directory held open, reached from a root one name at a time without
/// following a link. What is created, listed, or removed is
/// named inside this directory, never reached through a path again: a
/// level swapped for a link after it was opened takes nothing with it.
pub(crate) struct HeldDirectory(held::Inner);

/// What a listed entry is, as the directory says without following it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum EntryKind {
    Directory,
    /// A file, a link, or anything else that is not a directory.
    Other,
}

impl HeldDirectory {
    /// The directory `relative` names under `root` (`root` itself when
    /// empty), every name of it a directory and none a link.
    pub(crate) fn open(root: &Path, relative: &Path) -> io::Result<Self> {
        held::Inner::open(root, &names(relative)?).map(Self)
    }

    /// The directory `name` in this one, when it is a directory and not a
    /// link.
    pub(crate) fn child(&self, name: &std::ffi::OsStr) -> io::Result<Self> {
        self.0.child(name).map(Self)
    }

    /// The directory reached by `relative`, making missing levels when
    /// requested. Every level must be a directory and none may be a link.
    pub(crate) fn descend(&self, relative: &Path, is_making: bool) -> io::Result<Self> {
        self.0.descend(&names(relative)?, is_making).map(Self)
    }

    /// Creates and opens a new directory under this one.
    pub(crate) fn create_directory(&self, name: &std::ffi::OsStr) -> io::Result<Self> {
        self.0.create_directory(name).map(Self)
    }

    /// Creates a new file with checkout permissions, subject to the umask.
    pub(crate) fn create_file(
        &self,
        name: &std::ffi::OsStr,
        is_executable: bool,
    ) -> io::Result<std::fs::File> {
        self.0.create_file(name, is_executable)
    }

    /// Creates a link without opening its target or replacing any entry.
    pub(crate) fn create_symlink(&self, name: &std::ffi::OsStr, target: &[u8]) -> io::Result<()> {
        self.0.create_symlink(name, target)
    }

    /// Opens a regular file without following a link or waiting on a FIFO.
    pub(crate) fn read_file(&self, name: &std::ffi::OsStr) -> io::Result<std::fs::File> {
        self.0.read_file(name)
    }

    /// Whether both descriptors name the same directory.
    pub(crate) fn is_same(&self, other: &Self) -> bool {
        self.0.is_same(&other.0)
    }

    /// Renames an entry inside this directory only while the new name is free.
    pub(crate) fn rename_new(
        &self,
        from: &std::ffi::OsStr,
        to: &std::ffi::OsStr,
    ) -> io::Result<()> {
        self.0.rename_new(from, to)
    }

    /// The entries, without `.` and `..`.
    pub(crate) fn entries(&self) -> io::Result<Vec<(std::ffi::OsString, EntryKind)>> {
        self.0.entries()
    }

    /// Removes the entry `name` that is not a directory.
    pub(crate) fn remove_file(&self, name: &std::ffi::OsStr) -> io::Result<()> {
        self.0.unlink(name, false)
    }

    /// Removes the empty directory `name`.
    pub(crate) fn remove_dir(&self, name: &std::ffi::OsStr) -> io::Result<()> {
        self.0.unlink(name, true)
    }

    /// Removes `name` and, when it is a directory, everything in it, each
    /// level through the directory above it.
    pub(crate) fn remove_tree(&self, name: &std::ffi::OsStr) -> io::Result<()> {
        let Ok(child) = self.child(name) else {
            return self.remove_file(name);
        };
        for (entry, kind) in child.entries()? {
            match kind {
                EntryKind::Directory => child.remove_tree(&entry)?,
                EntryKind::Other => child.remove_file(&entry)?,
            }
        }
        self.remove_dir(name)
    }

    /// Removes the directories under `name` that hold nothing, and `name`
    /// itself when it is left empty.
    pub(crate) fn remove_empty_tree(&self, name: &std::ffi::OsStr) {
        let Ok(child) = self.child(name) else {
            return;
        };
        for (entry, kind) in child.entries().unwrap_or_default() {
            if kind == EntryKind::Directory {
                child.remove_empty_tree(&entry);
            }
        }
        let _ = self.remove_dir(name);
    }
}

#[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
mod held {
    use super::{EntryKind, beneath};
    use std::ffi::{CStr, OsStr, OsString};
    use std::fs::File;
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd};
    use std::os::unix::ffi::{OsStrExt, OsStringExt};
    use std::os::unix::fs::MetadataExt;
    use std::path::Path;

    pub(super) struct Inner(OwnedFd);

    impl Inner {
        pub(super) fn open(root: &Path, names: &[&OsStr]) -> io::Result<Self> {
            beneath::directory(root, names, false).map(Self)
        }

        pub(super) fn child(&self, name: &OsStr) -> io::Result<Self> {
            let name = beneath::c_string(name.as_bytes())?;
            beneath::open(
                self.0.as_raw_fd(),
                &name,
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW,
            )
            .map(Self)
        }

        pub(super) fn descend(&self, names: &[&OsStr], is_making: bool) -> io::Result<Self> {
            beneath::descend(self.0.try_clone()?, names, is_making).map(Self)
        }

        pub(super) fn create_directory(&self, name: &OsStr) -> io::Result<Self> {
            beneath::mkdir(self.0.as_raw_fd(), &beneath::c_string(name.as_bytes())?)?;
            self.child(name)
        }

        pub(super) fn create_file(&self, name: &OsStr, is_executable: bool) -> io::Result<File> {
            let mode: libc::c_uint = if is_executable { 0o777 } else { 0o666 };
            let name = beneath::c_string(name.as_bytes())?;
            let flags =
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC;
            // SAFETY: A directory we hold and a NUL-terminated name.
            let fd = unsafe { libc::openat(self.0.as_raw_fd(), name.as_ptr(), flags, mode) };
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: `openat` returned a descriptor we own.
            Ok(unsafe { File::from_raw_fd(fd) })
        }

        pub(super) fn create_symlink(&self, name: &OsStr, target: &[u8]) -> io::Result<()> {
            let name = beneath::c_string(name.as_bytes())?;
            let target = beneath::c_string(target)?;
            // SAFETY: A directory we hold and two NUL-terminated strings.
            if unsafe { libc::symlinkat(target.as_ptr(), self.0.as_raw_fd(), name.as_ptr()) } == 0 {
                Ok(())
            } else {
                Err(io::Error::last_os_error())
            }
        }

        pub(super) fn is_same(&self, other: &Self) -> bool {
            fn identity(fd: &OwnedFd) -> io::Result<(u64, u64)> {
                let metadata = File::from(fd.try_clone()?).metadata()?;
                Ok((metadata.dev(), metadata.ino()))
            }
            identity(&self.0).is_ok_and(|ours| identity(&other.0).is_ok_and(|other| ours == other))
        }

        pub(super) fn read_file(&self, name: &OsStr) -> io::Result<File> {
            let name = beneath::c_string(name.as_bytes())?;
            let fd = beneath::open(
                self.0.as_raw_fd(),
                &name,
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_NOCTTY,
            )?;
            let file = File::from(fd);
            if file.metadata()?.is_file() {
                Ok(file)
            } else {
                Err(io::Error::from(io::ErrorKind::InvalidInput))
            }
        }

        pub(super) fn rename_new(&self, from: &OsStr, to: &OsStr) -> io::Result<()> {
            let from = beneath::c_string(from.as_bytes())?;
            let to = beneath::c_string(to.as_bytes())?;
            // SAFETY: Both names are NUL-terminated and the directory stays open.
            #[cfg(target_os = "macos")]
            let status = unsafe {
                libc::renameatx_np(
                    self.0.as_raw_fd(),
                    from.as_ptr(),
                    self.0.as_raw_fd(),
                    to.as_ptr(),
                    libc::RENAME_EXCL,
                )
            };
            // SAFETY: Both names are NUL-terminated and the directory stays open.
            #[cfg(all(target_os = "linux", target_env = "gnu"))]
            let status = unsafe {
                libc::renameat2(
                    self.0.as_raw_fd(),
                    from.as_ptr(),
                    self.0.as_raw_fd(),
                    to.as_ptr(),
                    libc::RENAME_NOREPLACE,
                )
            };
            if status == 0 {
                Ok(())
            } else {
                Err(io::Error::last_os_error())
            }
        }

        pub(super) fn entries(&self) -> io::Result<Vec<(OsString, EntryKind)>> {
            // `fdopendir` takes the descriptor it is given and reads from
            // its position, so each listing opens `.` afresh: a `dup` would
            // share the position, and a second listing would start where
            // the first ended and find nothing. `.` is this directory
            // itself, so a level swapped for a link is still not followed.
            let copy = beneath::open(
                self.0.as_raw_fd(),
                &beneath::c_string(b".")?,
                libc::O_RDONLY | libc::O_DIRECTORY,
            )?
            .into_raw_fd();
            // SAFETY: `copy` is ours; on success the stream owns it.
            let stream = unsafe { libc::fdopendir(copy) };
            if stream.is_null() {
                let error = io::Error::last_os_error();
                // SAFETY: Not taken by a stream, so still ours to close.
                unsafe { libc::close(copy) };
                return Err(error);
            }
            let mut entries = Vec::new();
            loop {
                // SAFETY: A stream we opened and have not closed.
                let entry = unsafe { libc::readdir(stream) };
                if entry.is_null() {
                    break;
                }
                // SAFETY: `readdir` returned a valid entry, whose name is
                // NUL-terminated and lives until the next call.
                let (name, kind) =
                    unsafe { (CStr::from_ptr((*entry).d_name.as_ptr()), (*entry).d_type) };
                let bytes = name.to_bytes();
                if bytes == b"." || bytes == b".." {
                    continue;
                }
                let is_directory = match kind {
                    libc::DT_DIR => true,
                    libc::DT_UNKNOWN => self.is_directory(name),
                    _ => false,
                };
                entries.push((
                    OsString::from_vec(bytes.to_vec()),
                    if is_directory {
                        EntryKind::Directory
                    } else {
                        EntryKind::Other
                    },
                ));
            }
            // SAFETY: Closes the stream and the copy it owns.
            unsafe { libc::closedir(stream) };
            Ok(entries)
        }

        /// Asked of the entry itself, not of what a link points at.
        fn is_directory(&self, name: &CStr) -> bool {
            // SAFETY: `stat` is plain data; zeroed is a valid value.
            let mut stat: libc::stat = unsafe { std::mem::zeroed() };
            // SAFETY: A directory we hold, a NUL-terminated name, and a
            // writable struct.
            let status = unsafe {
                libc::fstatat(
                    self.0.as_raw_fd(),
                    name.as_ptr(),
                    &raw mut stat,
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            };
            status == 0 && stat.st_mode & libc::S_IFMT == libc::S_IFDIR
        }

        pub(super) fn unlink(&self, name: &OsStr, is_directory: bool) -> io::Result<()> {
            let name = beneath::c_string(name.as_bytes())?;
            let flags = if is_directory { libc::AT_REMOVEDIR } else { 0 };
            // SAFETY: A directory we hold and a NUL-terminated name.
            if unsafe { libc::unlinkat(self.0.as_raw_fd(), name.as_ptr(), flags) } == 0 {
                Ok(())
            } else {
                Err(io::Error::last_os_error())
            }
        }
    }
}

/// By path here, as the rest of this file is off macOS and Linux: only the
/// tests run on such a system.
#[cfg(not(any(target_os = "macos", all(target_os = "linux", target_env = "gnu"))))]
mod held {
    use super::EntryKind;
    use std::ffi::{OsStr, OsString};
    use std::fs;
    use std::io;
    use std::path::{Path, PathBuf};

    pub(super) struct Inner(PathBuf);

    impl Inner {
        pub(super) fn open(root: &Path, names: &[&OsStr]) -> io::Result<Self> {
            let path = names
                .iter()
                .fold(root.to_path_buf(), |path, name| path.join(name));
            Self::directory(path)
        }

        fn directory(path: PathBuf) -> io::Result<Self> {
            if fs::symlink_metadata(&path)?.is_dir() {
                Ok(Self(path))
            } else {
                Err(io::Error::from(io::ErrorKind::NotADirectory))
            }
        }

        pub(super) fn child(&self, name: &OsStr) -> io::Result<Self> {
            Self::directory(self.0.join(name))
        }

        pub(super) fn descend(&self, names: &[&OsStr], is_making: bool) -> io::Result<Self> {
            let mut at = self.0.clone();
            for name in names {
                at.push(name);
                if is_making
                    && let Err(error) = fs::create_dir(&at)
                    && error.kind() != io::ErrorKind::AlreadyExists
                {
                    return Err(error);
                }
                Self::directory(at.clone())?;
            }
            Ok(Self(at))
        }

        pub(super) fn create_directory(&self, name: &OsStr) -> io::Result<Self> {
            let path = self.0.join(name);
            fs::create_dir(&path)?;
            Self::directory(path)
        }

        pub(super) fn create_file(
            &self,
            name: &OsStr,
            is_executable: bool,
        ) -> io::Result<fs::File> {
            let mut options = fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(if is_executable { 0o777 } else { 0o666 });
            }
            #[cfg(not(unix))]
            let _ = is_executable;
            options.open(self.0.join(name))
        }

        pub(super) fn create_symlink(&self, name: &OsStr, target: &[u8]) -> io::Result<()> {
            let target = crate::git::path_from_bytes(target)
                .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
            #[cfg(unix)]
            return std::os::unix::fs::symlink(target, self.0.join(name));
            #[cfg(windows)]
            return std::os::windows::fs::symlink_file(target, self.0.join(name));
            #[cfg(not(any(unix, windows)))]
            {
                let _ = (name, target);
                Err(io::Error::from(io::ErrorKind::Unsupported))
            }
        }

        pub(super) fn is_same(&self, other: &Self) -> bool {
            // This implementation holds a path, not an open directory, so the
            // most it can tell is whether both name the same folder.
            self.0 == other.0
        }

        pub(super) fn read_file(&self, name: &OsStr) -> io::Result<fs::File> {
            let file = fs::File::open(self.0.join(name))?;
            if file.metadata()?.is_file() {
                Ok(file)
            } else {
                Err(io::Error::from(io::ErrorKind::InvalidInput))
            }
        }

        pub(super) fn rename_new(&self, from: &OsStr, to: &OsStr) -> io::Result<()> {
            super::platform::rename_new(&self.0, Path::new(from), Path::new(to))
        }

        pub(super) fn entries(&self) -> io::Result<Vec<(OsString, EntryKind)>> {
            Ok(fs::read_dir(&self.0)?
                .flatten()
                .map(|entry| {
                    let is_directory = entry.file_type().is_ok_and(|kind| kind.is_dir());
                    (
                        entry.file_name(),
                        if is_directory {
                            EntryKind::Directory
                        } else {
                            EntryKind::Other
                        },
                    )
                })
                .collect())
        }

        pub(super) fn unlink(&self, name: &OsStr, is_directory: bool) -> io::Result<()> {
            if is_directory {
                fs::remove_dir(self.0.join(name))
            } else {
                fs::remove_file(self.0.join(name))
            }
        }
    }
}

/// The names of `relative`, each a plain name: a path that climbs out or
/// starts at the root is refused.
fn names(relative: &Path) -> io::Result<Vec<&std::ffi::OsStr>> {
    relative
        .components()
        .map(|component| match component {
            Component::Normal(name) => Ok(name),
            _ => Err(io::Error::from(io::ErrorKind::InvalidInput)),
        })
        .collect()
}

/// Directories reached from the worktree one name at a time, never
/// through a link (`O_NOFOLLOW`), and the calls that act inside them.
#[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
mod beneath {
    use std::ffi::{CString, OsStr};
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;

    pub(super) fn c_string(bytes: &[u8]) -> io::Result<CString> {
        CString::new(bytes).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
    }

    pub(super) fn open(at: libc::c_int, name: &CString, flags: libc::c_int) -> io::Result<OwnedFd> {
        // SAFETY: `name` is NUL-terminated and lives across the call.
        let fd = unsafe { libc::openat(at, name.as_ptr(), flags | libc::O_CLOEXEC) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `openat` returned a descriptor we own.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }

    /// The worktree's own directory, as the caller names it.
    fn root(root: &Path) -> io::Result<OwnedFd> {
        let path = c_string(root.as_os_str().as_bytes())?;
        open(libc::AT_FDCWD, &path, libc::O_RDONLY | libc::O_DIRECTORY)
    }

    /// The directory `names` lead to from `root`, made where missing when
    /// `is_making`.
    pub(super) fn directory(root: &Path, names: &[&OsStr], is_making: bool) -> io::Result<OwnedFd> {
        descend(self::root(root)?, names, is_making)
    }

    pub(super) fn mkdir(at: libc::c_int, name: &CString) -> io::Result<()> {
        // SAFETY: A NUL-terminated name inside a directory we hold.
        if unsafe { libc::mkdirat(at, name.as_ptr(), 0o777) } == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }

    pub(super) fn descend(
        mut at: OwnedFd,
        names: &[&OsStr],
        is_making: bool,
    ) -> io::Result<OwnedFd> {
        for name in names {
            let name = c_string(name.as_bytes())?;
            if is_making
                && let Err(error) = mkdir(at.as_raw_fd(), &name)
                && error.kind() != io::ErrorKind::AlreadyExists
            {
                return Err(error);
            }
            at = open(
                at.as_raw_fd(),
                &name,
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW,
            )?;
        }
        Ok(at)
    }

    /// The directory holding `relative`, and its last name.
    pub(super) fn parent(root: &Path, relative: &Path) -> io::Result<(OwnedFd, CString)> {
        let names = super::names(relative)?;
        let (last, parents) = names
            .split_last()
            .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
        Ok((directory(root, parents, false)?, c_string(last.as_bytes())?))
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::beneath;
    use std::io;
    use std::os::fd::AsRawFd;
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;

    fn rename(root: &Path, from: &Path, to: &Path, flags: libc::c_uint) -> io::Result<()> {
        let (from_dir, from_name) = beneath::parent(root, from)?;
        let (to_dir, to_name) = beneath::parent(root, to)?;
        // SAFETY: Two directories we hold and two NUL-terminated names,
        // all alive across the call.
        let status = unsafe {
            libc::renameatx_np(
                from_dir.as_raw_fd(),
                from_name.as_ptr(),
                to_dir.as_raw_fd(),
                to_name.as_ptr(),
                flags,
            )
        };
        if status == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }

    pub(super) fn exchange(root: &Path, first: &Path, second: &Path) -> io::Result<()> {
        rename(root, first, second, libc::RENAME_SWAP)
    }

    pub(super) fn rename_new(root: &Path, from: &Path, to: &Path) -> io::Result<()> {
        rename(root, from, to, libc::RENAME_EXCL)
    }

    pub(super) fn make_parents(root: &Path, relative: &Path) -> io::Result<()> {
        let names = super::names(relative)?;
        let parents = names.split_last().map_or(&[][..], |(_, parents)| parents);
        beneath::directory(root, parents, true).map(drop)
    }

    /// What `getattrlist` writes for `ATTR_VOL_CAPABILITIES`: the length
    /// of the reply, then the attribute.
    #[repr(C)]
    struct Reply {
        length: u32,
        capabilities: libc::vol_capabilities_attr_t,
    }

    /// The volume's own answer (`VOL_CAP_INT_RENAME_SWAP` and
    /// `VOL_CAP_INT_RENAME_EXCL`, both valid and set), asked at its mount
    /// point.
    pub(super) fn can_exchange(path: &Path) -> bool {
        let Ok(path) = beneath::c_string(path.as_os_str().as_bytes()) else {
            return false;
        };
        // SAFETY: `statfs` is plain data; zeroed is a valid value.
        let mut volume: libc::statfs = unsafe { std::mem::zeroed() };
        // SAFETY: A NUL-terminated path and a writable struct.
        if unsafe { libc::statfs(path.as_ptr(), &raw mut volume) } != 0 {
            return false;
        }
        let mut list = libc::attrlist {
            bitmapcount: libc::ATTR_BIT_MAP_COUNT,
            reserved: 0,
            commonattr: 0,
            volattr: libc::ATTR_VOL_INFO | libc::ATTR_VOL_CAPABILITIES,
            dirattr: 0,
            fileattr: 0,
            forkattr: 0,
        };
        // SAFETY: Plain data; zeroed is a valid value.
        let mut reply: Reply = unsafe { std::mem::zeroed() };
        // SAFETY: The mount point is NUL-terminated by the kernel; the
        // reply buffer is as large as the size given.
        let status = unsafe {
            libc::getattrlist(
                volume.f_mntonname.as_ptr(),
                std::ptr::from_mut(&mut list).cast(),
                std::ptr::from_mut(&mut reply).cast(),
                std::mem::size_of::<Reply>(),
                0,
            )
        };
        if status != 0 {
            return false;
        }
        let wanted = libc::VOL_CAP_INT_RENAME_SWAP | libc::VOL_CAP_INT_RENAME_EXCL;
        let interfaces = libc::VOL_CAPABILITIES_INTERFACES;
        reply.capabilities.valid[interfaces] & wanted == wanted
            && reply.capabilities.capabilities[interfaces] & wanted == wanted
    }
}

#[cfg(all(target_os = "linux", target_env = "gnu"))]
mod platform {
    use super::beneath;
    use std::io;
    use std::os::fd::AsRawFd;
    use std::path::Path;

    fn rename(root: &Path, from: &Path, to: &Path, flags: libc::c_uint) -> io::Result<()> {
        let (from_dir, from_name) = beneath::parent(root, from)?;
        let (to_dir, to_name) = beneath::parent(root, to)?;
        // SAFETY: Two directories we hold and two NUL-terminated names,
        // all alive across the call.
        let status = unsafe {
            libc::renameat2(
                from_dir.as_raw_fd(),
                from_name.as_ptr(),
                to_dir.as_raw_fd(),
                to_name.as_ptr(),
                flags,
            )
        };
        if status == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }

    pub(super) fn exchange(root: &Path, first: &Path, second: &Path) -> io::Result<()> {
        rename(root, first, second, libc::RENAME_EXCHANGE)
    }

    pub(super) fn rename_new(root: &Path, from: &Path, to: &Path) -> io::Result<()> {
        rename(root, from, to, libc::RENAME_NOREPLACE)
    }

    pub(super) fn make_parents(root: &Path, relative: &Path) -> io::Result<()> {
        let names = super::names(relative)?;
        let parents = names.split_last().map_or(&[][..], |(_, parents)| parents);
        beneath::directory(root, parents, true).map(drop)
    }

    /// Not asked: `renameat2` fails with `EINVAL` where a file system has
    /// neither, and that path is reported as not written.
    pub(super) fn can_exchange(_path: &Path) -> bool {
        true
    }
}

/// Not one step here, and links are not refused: the app runs on macOS,
/// and this keeps the workspace's tests meaningful elsewhere.
#[cfg(not(any(target_os = "macos", all(target_os = "linux", target_env = "gnu"))))]
mod platform {
    use std::fs;
    use std::io;
    use std::path::Path;

    pub(super) fn exchange(root: &Path, first: &Path, second: &Path) -> io::Result<()> {
        let (first, second) = (root.join(first), root.join(second));
        let aside = first.with_file_name(format!(
            "{}.exchange",
            first
                .file_name()
                .map(|name| name.to_string_lossy())
                .unwrap_or_default()
        ));
        fs::rename(&second, &aside)?;
        if let Err(error) = fs::rename(&first, &second) {
            let _ = fs::rename(&aside, &second);
            return Err(error);
        }
        fs::rename(&aside, &first)
    }

    pub(super) fn rename_new(root: &Path, from: &Path, to: &Path) -> io::Result<()> {
        let to = root.join(to);
        if fs::symlink_metadata(&to).is_ok() {
            return Err(io::Error::from(io::ErrorKind::AlreadyExists));
        }
        fs::rename(root.join(from), to)
    }

    pub(super) fn make_parents(root: &Path, relative: &Path) -> io::Result<()> {
        match relative.parent() {
            Some(parent) => fs::create_dir_all(root.join(parent)),
            None => Ok(()),
        }
    }

    pub(super) fn can_exchange(_path: &Path) -> bool {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// A level swapped for a link after it was opened: what is removed
    /// through the held directory comes out of the directory that was
    /// checked, and nothing the link points at is touched.
    #[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
    #[test]
    fn a_held_directory_removes_through_what_it_opened_not_the_path() {
        let dir_scratch = tempfile::tempdir().expect("scratch");
        let dir = dir_scratch.path().to_path_buf();
        fs::create_dir_all(dir.join("area/gen-1/deep")).unwrap();
        fs::write(dir.join("area/gen-1/deep/half.txt"), "half").unwrap();
        fs::write(dir.join("area/.gitignore"), "*").unwrap();
        fs::create_dir_all(dir.join("elsewhere/gen-1")).unwrap();
        fs::write(dir.join("elsewhere/gen-1/keep.txt"), "keep").unwrap();

        let area = HeldDirectory::open(&dir, Path::new("area")).unwrap();
        // Between the check and the deletion, the level becomes a link.
        fs::rename(dir.join("area"), dir.join("moved")).unwrap();
        std::os::unix::fs::symlink(dir.join("elsewhere"), dir.join("area")).unwrap();

        let names: Vec<_> = area
            .entries()
            .unwrap()
            .into_iter()
            .map(|(name, _)| name)
            .collect();
        assert!(names.contains(&".gitignore".into()), "lists what it opened");
        area.remove_tree(std::ffi::OsStr::new("gen-1")).unwrap();

        assert_eq!(
            fs::read_to_string(dir.join("elsewhere/gen-1/keep.txt")).unwrap(),
            "keep"
        );
        assert!(!dir.join("moved/gen-1").exists());
        assert!(dir.join("moved/.gitignore").is_file());
        // A link is not a directory to open from here.
        let worktree = HeldDirectory::open(&dir, Path::new("")).unwrap();
        assert!(worktree.child(std::ffi::OsStr::new("area")).is_err());
        assert!(HeldDirectory::open(&dir, Path::new("area")).is_err());
    }

    /// Each listing starts at the first entry, however many came before:
    /// a cleanup lists a level, clears some of it, and lists it again to
    /// see whether anything is left.
    #[test]
    fn a_held_directory_lists_everything_every_time() {
        let dir_scratch = tempfile::tempdir().expect("scratch");
        let dir = dir_scratch.path().to_path_buf();
        fs::create_dir_all(dir.join("area/side")).unwrap();
        fs::write(dir.join("area/.gitignore"), "*").unwrap();

        let area = HeldDirectory::open(&dir, Path::new("area")).unwrap();
        let list = || {
            let mut names: Vec<_> = area
                .entries()
                .unwrap()
                .into_iter()
                .map(|(name, _)| name)
                .collect();
            names.sort();
            names
        };
        let first = list();
        assert_eq!(first, vec![".gitignore", "side"]);
        assert_eq!(list(), first);
        area.remove_tree(std::ffi::OsStr::new("side")).unwrap();
        assert_eq!(list(), [".gitignore"]);
    }

    #[test]
    fn exchange_swaps_two_files_and_rename_new_refuses_an_existing_one() {
        let dir_scratch = tempfile::tempdir().expect("scratch");
        let dir = dir_scratch.path().to_path_buf();
        let (first, second, third) = (Path::new("a"), Path::new("b"), Path::new("sub/c"));
        fs::write(dir.join(first), "a").unwrap();
        fs::write(dir.join(second), "b").unwrap();

        exchange(&dir, first, second).unwrap();
        assert_eq!(fs::read_to_string(dir.join(first)).unwrap(), "b");
        assert_eq!(fs::read_to_string(dir.join(second)).unwrap(), "a");

        let refused = rename_new(&dir, first, second).expect_err("something is there");
        assert_eq!(refused.kind(), std::io::ErrorKind::AlreadyExists);
        assert_eq!(fs::read_to_string(dir.join(first)).unwrap(), "b");
        assert_eq!(fs::read_to_string(dir.join(second)).unwrap(), "a");
        make_parents(&dir, third).unwrap();
        rename_new(&dir, first, third).unwrap();
        assert_eq!(fs::read_to_string(dir.join(third)).unwrap(), "b");
        assert!(!dir.join(first).exists());
        assert!(can_exchange(&dir), "the temporary directory's volume does");
    }

    /// A directory that is a link is not gone through, wherever it leads.
    #[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
    #[test]
    fn a_link_in_the_path_is_not_followed() {
        let dir_scratch = tempfile::tempdir().expect("scratch");
        let dir = dir_scratch.path().to_path_buf();
        let outside_scratch = tempfile::tempdir().expect("scratch");
        let outside = outside_scratch.path().to_path_buf();
        fs::write(dir.join("a"), "a").unwrap();
        fs::write(outside.join("b"), "outside").unwrap();
        std::os::unix::fs::symlink(&outside, dir.join("linked")).unwrap();

        assert!(exchange(&dir, Path::new("a"), Path::new("linked/b")).is_err());
        assert!(rename_new(&dir, Path::new("a"), Path::new("linked/c")).is_err());
        assert!(make_parents(&dir, Path::new("linked/d/e")).is_err());
        assert_eq!(fs::read_to_string(outside.join("b")).unwrap(), "outside");
        assert_eq!(fs::read_to_string(dir.join("a")).unwrap(), "a");
        assert_eq!(fs::read_link(dir.join("linked")).unwrap(), outside);
        assert!(!outside.join("c").exists() && !outside.join("d").exists());
    }
}
