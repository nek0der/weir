// SettingsFileWatcherTests.swift
// Weir — what the watcher picks up from disk, and which fds canceling it closes.
//
// The cancel handler captures the fd by value, so it closes the fd that
// source watched, never one a re-armed watcher opened since.

import Darwin
import Foundation
import Testing
@testable import Weir

@MainActor
struct SettingsFileWatcherTests {

    @Test("cancel closes the watched directory fd")
    func cancelClosesFD() async throws {
        try await withTempDir { dir in
            let store = SettingsStore(directory: dir)
            let watcher = SettingsFileWatcher(store: store)
            watcher.start()
            let fd = watcher.currentDirFD
            try #require(fd >= 0)
            var watchedDirectory = stat()
            try #require(fstat(fd, &watchedDirectory) == 0)

            watcher.stop()
            await expectClosed(fd, thatNamed: watchedDirectory)
        }
    }

    @Test("cancel closes the watched file fd")
    func cancelClosesFileFD() async throws {
        try await withTempDir { dir in
            let store = try SettingsStore.inEnglish(in: dir)
            try write(minPaneSize: 120, to: store, options: .atomic)
            let watcher = SettingsFileWatcher(store: store)
            watcher.start()
            let fd = watcher.currentFileFD
            try #require(fd >= 0)
            var watchedFile = stat()
            try #require(fstat(fd, &watchedFile) == 0)

            watcher.stop()
            await expectClosed(fd, thatNamed: watchedFile)
            #expect(watcher.currentFileFD == -1)
        }
    }

    /// A save in place reports nothing on the directory, so the third step
    /// needs the file's source to have followed the replace in the second.
    @Test("an in-place write, an atomic replace, and an in-place write after it are all picked up")
    func picksUpWritesAcrossAReplace() async throws {
        try await withTempDir { dir in
            let store = try SettingsStore.inEnglish(in: dir)
            try write(minPaneSize: 120, to: store, options: .atomic)
            // The expected values below are then the only change to come.
            store.reloadFromDisk()
            let watcher = SettingsFileWatcher(store: store)
            watcher.start()
            defer { watcher.stop() }

            try write(minPaneSize: 140, to: store, options: [])
            await expectReload(of: store, toMinPaneSize: 140)

            try write(minPaneSize: 160, to: store, options: .atomic)
            await expectReload(of: store, toMinPaneSize: 160)

            try write(minPaneSize: 180, to: store, options: [])
            await expectReload(of: store, toMinPaneSize: 180)
        }
    }

    @Test("an atomic replace closes the old file fd and holds the new file")
    func replaceClosesOldFileFD() async throws {
        try await withTempDir { dir in
            let store = try SettingsStore.inEnglish(in: dir)
            try write(minPaneSize: 120, to: store, options: .atomic)
            let watcher = SettingsFileWatcher(store: store)
            watcher.start()
            defer { watcher.stop() }
            let oldFD = watcher.currentFileFD
            try #require(oldFD >= 0)
            var oldFile = stat()
            try #require(fstat(oldFD, &oldFile) == 0)

            try write(minPaneSize: 140, to: store, options: .atomic)
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(10)) {
                holdsNamedFile(watcher, store)
            }

            #expect(holdsNamedFile(watcher, store))
            await expectClosed(oldFD, thatNamed: oldFile)
        }
    }

    /// What a save that stalls looks like from here: the first half lands,
    /// the debounce runs out, and the rest arrives later.
    @Test("a save read half done costs neither the file nor the settings")
    func aSaveReadHalfDoneIsKept() async throws {
        try await withTempDir { dir in
            let store = try SettingsStore.inEnglish(in: dir)
            try write(minPaneSize: 120, to: store, options: .atomic)
            store.reloadFromDisk()
            let watcher = SettingsFileWatcher(store: store)
            watcher.start()
            defer { watcher.stop() }

            let halfDone = Data(#"{ "terminal": "#.utf8)
            try halfDone.write(to: store.settingsFileURL)
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(10)) {
                store.savingSuspension == .doesNotDecode
            }
            #expect(store.savingSuspension == .doesNotDecode)
            #expect(store.settings.terminal.minPaneSize == 120)
            #expect(try Data(contentsOf: store.settingsFileURL) == halfDone)

            try write(minPaneSize: 140, to: store, options: [])
            await expectReload(of: store, toMinPaneSize: 140)
            #expect(store.savingSuspension == nil)
        }
    }

    @Test("a file deleted and created again is watched again")
    func picksUpWritesAfterADelete() async throws {
        try await withTempDir { dir in
            let store = try SettingsStore.inEnglish(in: dir)
            try write(minPaneSize: 120, to: store, options: .atomic)
            // The expected values below are then the only change to come.
            store.reloadFromDisk()
            let watcher = SettingsFileWatcher(store: store)
            watcher.start()
            defer { watcher.stop() }

            try FileManager.default.removeItem(at: store.settingsFileURL)
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(10)) {
                watcher.currentFileFD == -1
            }
            #expect(watcher.currentFileFD == -1)

            try write(minPaneSize: 140, to: store, options: [])
            await expectReload(of: store, toMinPaneSize: 140)

            try write(minPaneSize: 160, to: store, options: [])
            await expectReload(of: store, toMinPaneSize: 160)
        }
    }

    /// Whether the watcher's fd is on the inode the settings file's name leads to.
    private func holdsNamedFile(_ watcher: SettingsFileWatcher, _ store: SettingsStore) -> Bool {
        var held = stat()
        var named = stat()
        guard fstat(watcher.currentFileFD, &held) == 0, stat(store.settingsFileURL.path, &named) == 0 else { return false }
        return held.st_dev == named.st_dev && held.st_ino == named.st_ino
    }

    /// Writes the file the way another tool would, leaving the store's memory
    /// alone. `options` chooses between in place (`[]`) and a rename (`.atomic`).
    private func write(minPaneSize: Double, to store: SettingsStore, options: Data.WritingOptions) throws {
        var edited = store.settings
        edited.terminal.minPaneSize = minPaneSize
        try WeirSettings.makeFileEncoder().encode(edited).write(to: store.settingsFileURL, options: options)
    }

    /// The deadline stands well past the debounce, which a full parallel run
    /// can keep waiting on the main actor.
    private func expectReload(
        of store: SettingsStore,
        toMinPaneSize expected: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await pollUntil(timeout: .seconds(10), interval: .milliseconds(10)) {
            store.settings.terminal.minPaneSize == expected
        }
        #expect(store.settings.terminal.minPaneSize == expected, sourceLocation: sourceLocation)
    }

    private func expectClosed(_ fd: CInt, thatNamed watched: stat, sourceLocation: SourceLocation = #_sourceLocation) async {
        // The cancel handler runs on the source's main queue: wait until
        // the descriptor no longer names what it watched, rather than a
        // fixed turn.
        await pollUntil(interval: .milliseconds(10)) {
            var now = stat()
            return fstat(fd, &now) == -1 || now.st_dev != watched.st_dev || now.st_ino != watched.st_ino
        }

        var currentDescriptor = stat()
        if fstat(fd, &currentDescriptor) == -1 {
            #expect(errno == EBADF, sourceLocation: sourceLocation)
        } else {
            // Swift Testing runs suites concurrently, so the kernel may reuse
            // the integer immediately. In that case, prove it no longer names
            // the unique inode that this watcher opened.
            #expect(
                currentDescriptor.st_dev != watched.st_dev
                    || currentDescriptor.st_ino != watched.st_ino,
                sourceLocation: sourceLocation
            )
        }
    }
}
