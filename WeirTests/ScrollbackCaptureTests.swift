// ScrollbackCaptureTests.swift
// Weir — the capture at ⌘Q that fills the session's scrollback folder, what it leaves alone, and the rule a tab's close shares with it.

import Foundation
import Testing
@testable import Weir

@MainActor
struct ScrollbackCaptureTests {
    /// Runs `body` with a scrollback folder of its own, which exists,
    /// spelled as the file system lists its files (`/private/var/…`), so
    /// the paths a capture records match the ones the prune reads back.
    private func withFiles(_ body: (ScrollbackFiles) throws -> Void) throws {
        try withTempDir { dir in
            let resolved = dir.appendingPathComponent("scrollback", isDirectory: true).resolvingSymlinksInPath()
            let directory = resolved.path.hasPrefix("/var/")
                ? URL(fileURLWithPath: "/private" + resolved.path, isDirectory: true)
                : resolved
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try body(ScrollbackFiles(directory: directory))
        }
    }

    @Test func aRunThatMayNotWrite_leavesTheScrollbackFilesAlone() throws {
        // Demo mode at ⌘Q: the prune would delete the files the person's own
        // state.json points at.
        try withFiles { files in
            let kept = files.directory.appendingPathComponent("\(UUID().uuidString).vt")
            try Data("scrollback".utf8).write(to: kept)
            let session = WorkspaceSession()
            session.scrollbackFiles = files
            session.writesUserFiles = false

            session.captureScrollbackPaths(from: NoopSurfaceRegistry())

            #expect(FileManager.default.fileExists(atPath: kept.path))
        }
    }

    @Test func capture_writesEachMountedPaneToTheSessionsFolder_andPrunesTheRest() throws {
        try withFiles { files in
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            session.scrollbackFiles = files
            let stray = files.directory.appendingPathComponent("\(UUID().uuidString).vt")
            try Data("old".utf8).write(to: stray)
            let registry = RecordingSurfaceRegistry()
            registry.scrollback[pane] = "prompt$ ls"

            session.captureScrollbackPaths(from: registry)

            let saved = files.directory.appendingPathComponent("\(pane.uuidString).vt")
            #expect(session.tab(tab.id)?.scrollbackPaths[pane] == saved.path)
            #expect(try String(contentsOf: saved, encoding: .utf8) == "prompt$ ls")
            let mode = try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            #expect(!FileManager.default.fileExists(atPath: stray.path))
        }
    }

    @Test func capture_afterStateWasSetAside_keepsTheFilesNoTabNames() throws {
        // The set-aside state.json still names them: renaming it back must
        // bring its panes' scrollback back too.
        try withFiles { files in
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            session.scrollbackFiles = files
            session.keepsUnreferencedFiles = true
            let setAsidePanes = files.directory.appendingPathComponent("\(UUID().uuidString).vt")
            try Data("set aside".utf8).write(to: setAsidePanes)
            let registry = RecordingSurfaceRegistry()
            registry.scrollback[pane] = "prompt$ ls"

            session.captureScrollbackPaths(from: registry)

            let saved = files.directory.appendingPathComponent("\(pane.uuidString).vt")
            #expect(session.tab(tab.id)?.scrollbackPaths[pane] == saved.path)
            #expect(FileManager.default.fileExists(atPath: setAsidePanes.path))
        }
    }

    @Test func capture_keepsAnUnmountedPanesEarlierFile() throws {
        // A restored tab the person never clicked into has no terminal this
        // run; its earlier file is what the next launch replays.
        try withFiles { files in
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            session.scrollbackFiles = files
            let earlier = files.directory.appendingPathComponent("\(pane.uuidString).vt")
            try Data("earlier".utf8).write(to: earlier)
            _ = session.update(tab.id) { $0.scrollbackPaths[pane] = earlier.path }

            session.captureScrollbackPaths(from: RecordingSurfaceRegistry())

            #expect(session.tab(tab.id)?.scrollbackPaths[pane] == earlier.path)
            #expect(FileManager.default.fileExists(atPath: earlier.path))
        }
    }

    @Test func aSessionHandedNoFolder_savesNoScrollback() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let registry = RecordingSurfaceRegistry()
        registry.scrollback[pane] = "text"

        session.captureScrollbackPaths(from: registry)

        #expect(session.tab(tab.id)?.scrollbackPaths.isEmpty == true)
    }

    // MARK: - The capture rule ⌘Q and a tab's close share

    @Test func capturePaths_aFreshDumpWinsOverTheInheritedPath() throws {
        try withFiles { files in
            let pane = UUID()
            let registry = RecordingSurfaceRegistry()
            registry.scrollback[pane] = "fresh"

            let paths = files.capturePaths(of: [pane], inheriting: [pane: "/earlier.vt"], with: registry)

            let saved = files.directory.appendingPathComponent("\(pane.uuidString).vt")
            #expect(paths == [pane: saved.path])
        }
    }

    @Test func capturePaths_keepsTheInheritedPath_whenThePaneHasNoDump() throws {
        try withFiles { files in
            let mounted = UUID()
            let unmounted = UUID()
            let registry = RecordingSurfaceRegistry()
            registry.scrollback[mounted] = "fresh"

            let paths = files.capturePaths(
                of: [mounted, unmounted],
                inheriting: [unmounted: "/earlier.vt"],
                with: registry
            )

            #expect(paths[unmounted] == "/earlier.vt")
            #expect(paths[mounted] == files.directory.appendingPathComponent("\(mounted.uuidString).vt").path)
        }
    }

    @Test func capturePaths_dropsPanesOutsideTheLeaves() throws {
        try withFiles { files in
            let leaf = UUID()
            let gone = UUID()
            let registry = RecordingSurfaceRegistry()
            registry.scrollback[gone] = "a closed split"

            let paths = files.capturePaths(of: [leaf], inheriting: [gone: "/gone.vt"], with: registry)

            #expect(paths.isEmpty)
        }
    }

    // MARK: - A restored pane's path, kept until its terminal is made

    @Test func scrollbackPath_staysInTheTab_untilItIsForgotten() {
        // Reading it is what staging a terminal does; the terminal may never
        // be made, so the tab keeps the path until it is.
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        _ = session.update(tab.id) { $0.scrollbackPaths[pane] = "/saved.vt" }

        #expect(session.scrollbackPath(ofPane: pane) == "/saved.vt")
        #expect(session.scrollbackPath(ofPane: pane) == "/saved.vt")

        session.forgetScrollbackPath(ofPane: pane)

        #expect(session.tab(tab.id)?.scrollbackPaths[pane] == nil)
        #expect(session.scrollbackPath(ofPane: pane) == nil)
    }

    @Test func forgetScrollbackPath_findsAPaneThatMovedToAnotherTab() throws {
        // The pane's path goes with it when it moves; the terminal made
        // afterwards replays it there, and it is forgotten there.
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        _ = session.update(tab.id) {
            $0.splitTree = $0.splitTree.insert(at: pane, direction: .horizontal).tree
            $0.scrollbackPaths[pane] = "/saved.vt"
        }
        TabActions.movePaneToNewTab(session, paneID: pane)
        let moved = try #require(session.tab(containing: pane))
        #expect(moved.id != tab.id)
        #expect(moved.scrollbackPaths[pane] == "/saved.vt")

        session.forgetScrollbackPath(ofPane: pane)

        #expect(session.tab(moved.id)?.scrollbackPaths[pane] == nil)
    }

    @Test func scrollbackPath_leavesAnEmptyPathInPlace() {
        // An empty path was never a file to replay; forgetting it would
        // change the tab for nothing.
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        _ = session.update(tab.id) { $0.scrollbackPaths[pane] = "" }

        #expect(session.scrollbackPath(ofPane: pane) == nil)
        session.forgetScrollbackPath(ofPane: pane)
        #expect(session.tab(tab.id)?.scrollbackPaths[pane] == "")
    }

    // MARK: - A tab's close

    @Test func closingARestoredTabNeverMounted_keepsItsScrollbackForReopen() throws {
        // A restored tab the person never clicked into has no terminal to
        // dump; its earlier file is what ⌘⇧T replays.
        try withFiles { files in
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            session.scrollbackFiles = files
            let earlier = files.directory.appendingPathComponent("\(pane.uuidString).vt")
            try Data("earlier".utf8).write(to: earlier)
            _ = session.update(tab.id) { $0.scrollbackPaths[pane] = earlier.path }

            TabActions.closeTab(session, registry: RecordingSurfaceRegistry(), tabID: tab.id)

            #expect(session.closedTabStack.last?.tab.scrollbackPaths == [pane: earlier.path])
            TabActions.reopenClosedTab(session)
            let revived = try #require(session.tabs.last)
            let revivedPane = try #require(revived.splitTree.allLeafIDs().first)
            #expect(revived.scrollbackPaths == [revivedPane: earlier.path])
            #expect(FileManager.default.fileExists(atPath: earlier.path))
        }
    }

    @Test func closingAMountedPane_keepsItsFreshDump_overTheInheritedPath() throws {
        try withFiles { files in
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            session.scrollbackFiles = files
            _ = session.update(tab.id) { $0.scrollbackPaths[pane] = "/earlier.vt" }
            let registry = RecordingSurfaceRegistry()
            registry.scrollback[pane] = "fresh"

            TabActions.closeTab(session, registry: registry, tabID: tab.id)

            let saved = files.directory.appendingPathComponent("\(pane.uuidString).vt")
            #expect(session.closedTabStack.last?.tab.scrollbackPaths == [pane: saved.path])
        }
    }

    @Test func aClosedTabLeavingTheStack_deletesOnlyItsFilesInTheFolder() throws {
        // A restored path came from state.json, which a tampered file could
        // point anywhere; the stack's cap must not delete what it names.
        try withFiles { files in
            let session = WorkspaceSession()
            session.scrollbackFiles = files
            let ours = files.directory.appendingPathComponent("\(UUID().uuidString).vt")
            try Data("ours".utf8).write(to: ours)
            let outside = files.directory.deletingLastPathComponent().appendingPathComponent("outside.vt")
            try Data("not ours".utf8).write(to: outside)
            let oldest = session.openTab(container: .loose)
            let first = try #require(oldest.splitTree.allLeafIDs().first)
            let second = UUID()
            _ = session.update(oldest.id) {
                $0.splitTree = $0.splitTree.insert(at: first, direction: .horizontal, newID: second).tree
                $0.scrollbackPaths = [first: ours.path, second: outside.path]
            }
            TabActions.closeTab(session, registry: RecordingSurfaceRegistry(), tabID: oldest.id)

            for _ in 0..<WorkspaceSession.closedTabStackLimit {
                let tab = session.openTab(container: .loose)
                TabActions.closeTab(session, registry: RecordingSurfaceRegistry(), tabID: tab.id)
            }

            #expect(!session.closedTabStack.contains { $0.tab.id == oldest.id })
            #expect(!FileManager.default.fileExists(atPath: ours.path))
            #expect(FileManager.default.fileExists(atPath: outside.path))
        }
    }
}
