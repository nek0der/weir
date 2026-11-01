// SettingsFileWatcher.swift
// Weir — watches `settings.json` for external edits (the user
// hand-editing the file, or another tool writing to it) and
// triggers `SettingsStore.reloadFromDisk()` after a short debounce.
//
// We watch the file and its **parent directory**, because each sees
// what the other cannot. A save in place (`open(path, "w")`) keeps the
// inode and leaves the directory alone, so only the file's own source
// reports it. Most editors instead save atomically: write to a temp
// file, then `rename(2)` over the target. That changes the inode, which
// leaves a source attached to the old one with nothing more to report,
// and a file created after a delete has no source yet. The directory
// reports both, so we can re-acquire the file across them.
//
// 200ms debounce is long enough to
// coalesce an editor's atomic-save bursts (write, fsync, rename),
// short enough that the user perceives the change as instant.

import Foundation
import OSLog

private let log = Logger.weir("settings.watcher")

@MainActor
final class SettingsFileWatcher {
    private weak var store: SettingsStore?

    /// `nonisolated(unsafe)` so deinit (nonisolated under Swift 6)
    /// can cancel the sources to clean up. Matches the sibling
    /// DispatchSource watcher in `AgentProjectionAdapter`.
    private nonisolated(unsafe) var dirSource: (any DispatchSourceFileSystemObject)?
    private nonisolated(unsafe) var fileSource: (any DispatchSourceFileSystemObject)?
    private var dirFD: CInt = -1
    private var fileFD: CInt = -1

    #if DEBUG
        /// Test seam: read the watched directory's file descriptor so a
        /// lifecycle test can assert it closes when the source is
        /// canceled. The cancel handler closes the fd it captured by value,
        /// not whatever `dirFD` holds then, and only this accessor lets a
        /// test see which one it was.
        var currentDirFD: CInt {
            dirFD
        }

        /// Test seam: the same for `settings.json` itself, -1 while there
        /// is no file to watch.
        var currentFileFD: CInt {
            fileFD
        }
    #endif
    private var debounceTask: Task<Void, Never>?

    private static let debounce: Duration = .milliseconds(200)

    init(store: SettingsStore) {
        self.store = store
    }

    deinit {
        // Close ownership lives in the cancel handler `makeSource`
        // sets — calling `close(dirFD)` here
        // too would double-close the same fd if the source hasn't
        // finished tearing down yet. The cancel handler runs as soon
        // as the source is fully torn down, so leaving it to handle
        // the close is both correct and race-free.
        dirSource?.cancel()
        fileSource?.cancel()
    }

    /// Start watching. Safe to call multiple times — the second call
    /// is a no-op while the first source is still live.
    func start() {
        guard dirSource == nil else { return }
        guard let url = store?.settingsFileURL else { return }
        let dir = url.deletingLastPathComponent()

        // Make sure the directory exists so `open` doesn't fail on a
        // fresh install where settings.json hasn't been written yet.
        SecureFileWrite.ensureUserOnlyDirectory(dir)

        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("open() on \(dir.path, privacy: .private) failed: errno \(errno, privacy: .public)")
            return
        }
        self.dirFD = fd

        self.dirSource = makeSource(fd: fd, eventMask: [.write, .rename, .delete])
        // After the directory source, so a replace that lands between the
        // two is reported and re-acquired rather than missed.
        acquireFile()
        log.notice("settings.json watcher armed on \(dir.path, privacy: .private)")
    }

    func stop() {
        // Same rationale as `deinit`: the fd close is owned by the
        // dispatch source's cancel handler, so we just cancel here
        // and let the source close on tear-down.
        dirSource?.cancel()
        dirSource = nil
        dirFD = -1
        releaseFile()
    }

    /// Re-acquires the file when the name no longer leads to the inode we
    /// hold, then reloads. Both sources land here: a rename or delete reaches
    /// the file's source, and a file created where there was none reaches
    /// only the directory's. An event that changed nothing re-acquires nothing.
    private func fileMayHaveChanged() {
        acquireFile()
        scheduleReload()
    }

    /// Points the file's source at whatever `settings.json` names now. No
    /// file means no source, which is not a failure: the directory reports
    /// the file's creation, and that comes back here.
    private func acquireFile() {
        guard let url = store?.settingsFileURL else { return }
        if fileSource != nil, isHeldFile(at: url) {
            return
        }
        releaseFile()

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            if errno != ENOENT {
                log.error("open() on \(url.path, privacy: .private) failed: errno \(errno, privacy: .public)")
            }
            return
        }
        self.fileFD = fd

        // Not `.attrib`: a truncate reports only that, and the file is empty
        // until the write that follows reports for itself. A save that stalls
        // later than that can still be read half done;
        // `SettingsStore.reloadFromDisk` keeps the file and the settings then.
        self.fileSource = makeSource(fd: fd, eventMask: [.write, .extend, .rename, .delete])
    }

    /// A running source that owns `fd`: its cancel handler closes the fd it
    /// captured by value, so a re-armed watcher's fd is never the one closed.
    private func makeSource(fd: CInt, eventMask: DispatchSource.FileSystemEvent) -> any DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: eventMask,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.fileMayHaveChanged()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        return source
    }

    /// Whether `url` still leads to the inode we hold. Our fd keeps that
    /// inode allocated, so its number cannot have been given to a new file.
    private func isHeldFile(at url: URL) -> Bool {
        var held = stat()
        var named = stat()
        guard fstat(fileFD, &held) == 0, stat(url.path, &named) == 0 else { return false }
        return held.st_dev == named.st_dev && held.st_ino == named.st_ino
    }

    /// Same rationale as `deinit`: the cancel handler owns the close.
    private func releaseFile() {
        fileSource?.cancel()
        fileSource = nil
        fileFD = -1
    }

    /// Debounce reload requests. An editor's atomic save fires
    /// multiple events (rename + write) within a few ms — we want
    /// one reload at the tail, not a burst.
    private func scheduleReload() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.store?.reloadFromDisk()
        }
    }
}
