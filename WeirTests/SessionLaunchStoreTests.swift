// SessionLaunchStoreTests.swift
// Weir — a new worktree's copy, setup, and what it opens: each stage in order, each failure kept and retried, its notes.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionLaunchStoreTests {
    typealias Fixture = SessionLaunchFixture

    /// An agent's tab that opened with no pane cannot start its agent: a
    /// failure at that stage, which the row says and "Retry" can take, not
    /// a launch that quietly ends with nothing to say why. A shell's, and
    /// nothing, have no start to wait for either way.
    @Test func anAgentsTabWithNoPane_failsToStart() {
        let pane = UUID()
        let agent = SessionLaunchRequest(open: .agent(.claude))
        #expect(SessionLaunchStore.outcome(of: agent, paneID: pane) == .starting(pane))
        #expect(SessionLaunchStore.outcome(of: agent, paneID: nil) == .failed)
        for other in [SessionLaunchRequest(open: .shell), SessionLaunchRequest(open: .nothing)] {
            #expect(SessionLaunchStore.outcome(of: other, paneID: pane) == .finished)
            #expect(SessionLaunchStore.outcome(of: other, paneID: nil) == .finished)
        }
    }

    /// The request carries an executable for an agent only.
    @Test func aRequestsExecutable_isAnAgentsOnly() {
        #expect(SessionLaunchRequest(open: .agent(.codex), executable: "/x/codex").executable == "/x/codex")
        #expect(SessionLaunchRequest(open: .shell, executable: "/x/codex").executable == nil)
        #expect(SessionLaunchRequest(open: .nothing, executable: "/x/codex").executable == nil)
    }

    private static func startingPane(in fixture: Fixture, store: SessionLaunchStore, command: String) throws -> UUID {
        let id = fixture.worktree.id
        let launch = try #require(store.launches[id])
        try #require(launch.phase == .starting(isLaunched: false))
        let pane = try #require(launch.paneID)
        let tab = try #require(fixture.tabs.first)
        #expect(fixture.tabs.count == 1)
        #expect(tab.splitTree.allLeafIDs() == [pane])
        #expect(tab.initialCommands == [pane: command])
        #expect(tab.initialPromptFiles.isEmpty)
        return pane
    }

    @Test func afterTheSetup_theAgentsTabOpens_withNoInstruction_andWaitsForItsStart() async throws {
        try await withTempDir { dir in
            let first = "printf first > setup-log"
            let fixture = try await Fixture.make(in: dir, bootstrap: [
                .shorthand(first), .shorthand("printf second >> setup-log")
            ])
            let path = Gate<Void>()
            defer { path.open() }
            let store = SessionLaunchStore(path: {
                await path.wait()
                return Fixture.path
            }, git: fixture.git)
            let id = fixture.worktree.id
            store.begin(projectID: fixture.project.id, worktreeID: id, request: .init(open: .agent(.codex)), in: fixture.session)
            try await path.waitUntilRequested()
            #expect(store.launches[id]?.phase == .settingUp(stepIndex: 0, stepCount: 2, command: first))
            #expect(fixture.tabs.isEmpty)

            path.open()
            await pollUntil(timeout: .seconds(10)) { store.launches[id]?.phase == .starting(isLaunched: false) }
            let log = fixture.worktree.workingDirectory.appendingPathComponent("setup-log")
            #expect(try String(contentsOf: log, encoding: .utf8) == "firstsecond")
            _ = try Self.startingPane(in: fixture, store: store, command: "codex")
        }
    }

    @Test func aFailedStep_keepsTheStage_andTheRetryRunsFromIt_inTheSameWorktree() async throws {
        try await withTempDir { dir in
            let second = "test -f marker || { echo 'missing marker' >&2; exit 3; }; printf second >> setup-log"
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand("printf first >> setup-log"), .shorthand(second)])
            let id = fixture.worktree.id
            let worktree = fixture.worktree.workingDirectory
            let log = worktree.appendingPathComponent("setup-log")
            fixture.begin()
            await pollUntil(timeout: .seconds(10)) { fixture.store.launches[id]?.failure != nil }
            let failure = try #require(fixture.store.launches[id]?.failure)
            #expect(failure.stage == .setup(stepIndex: 1))
            #expect(failure.logTail == "missing marker")
            #expect(fixture.tabs.isEmpty)
            #expect(try String(contentsOf: log, encoding: .utf8) == "first")

            try Data().write(to: worktree.appendingPathComponent("marker"))
            fixture.store.retry(worktreeID: id, in: fixture.session)
            #expect(fixture.store.launches[id]?.phase == .settingUp(stepIndex: 1, stepCount: 2, command: second))
            await pollUntil(timeout: .seconds(10)) { fixture.store.launches[id]?.phase == .starting(isLaunched: false) }
            _ = try Self.startingPane(in: fixture, store: fixture.store, command: "claude")
            #expect(try String(contentsOf: log, encoding: .utf8) == "firstsecond")
            #expect(fixture.session.project(fixture.project.id)?.worktrees.map(\.id) == [id])
            #expect(fixture.session.worktree(projectID: fixture.project.id, worktreeID: id)?.workingDirectory == worktree)
        }
    }

    @Test func aProjectWithoutSetup_opensTheAgentsTabWithoutWaitingForSetup() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            fixture.begin()
            _ = try Self.startingPane(in: fixture, store: fixture.store, command: "claude")
        }
    }

    /// Skipping configured setup never requests a setup PATH.
    @Test func aSetupNotAskedFor_doesNotRun() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand("touch ran")])
            let requestedPath = Recorded(false)
            let store = SessionLaunchStore(path: {
                requestedPath.value = true
                return Fixture.path
            }, git: fixture.git)
            store.begin(
                projectID: fixture.project.id,
                worktreeID: fixture.worktree.id,
                request: .init(open: .agent(.claude), runsSetup: false),
                in: fixture.session
            )
            _ = try Self.startingPane(in: fixture, store: store, command: "claude")
            #expect(!requestedPath.value)
            #expect(!FileManager.default.fileExists(atPath: fixture.worktree.workingDirectory.appendingPathComponent("ran").path))
        }
    }

    /// A shell, and nothing, have no CLI to wait 30 seconds for: the launch
    /// ends as the setup does, with a shell's tab or none.
    @Test func aShellOrNothing_endsTheLaunchAtOnce() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            fixture.begin(SessionLaunchRequest(open: .shell))
            #expect(fixture.store.launches.isEmpty)
            #expect(!fixture.store.isFollowing)
            let tab = try #require(fixture.tabs.first)
            #expect(fixture.tabs.count == 1)
            #expect(tab.agentsInFront.isEmpty)
            #expect(tab.initialCommands.isEmpty)
        }
        try await withTempDir { dir in
            let command = "printf ran > setup-log"
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand(command)])
            let id = fixture.worktree.id
            fixture.begin(SessionLaunchRequest(open: .nothing))
            try #require(fixture.store.launches[id]?.phase == .settingUp(stepIndex: 0, stepCount: 1, command: command))
            await pollUntil(timeout: .seconds(10)) { fixture.store.launches.isEmpty }
            #expect(fixture.store.launches.isEmpty)
            #expect(fixture.tabs.isEmpty)
            let log = fixture.worktree.workingDirectory.appendingPathComponent("setup-log")
            #expect(try String(contentsOf: log, encoding: .utf8) == "ran")
        }
    }

    /// Starts Claude with no setup and returns its pane.
    private static func startAgent(_ fixture: Fixture) throws -> UUID {
        fixture.begin(SessionLaunchRequest(open: .agent(.claude)))
        return try startingPane(in: fixture, store: fixture.store, command: "claude")
    }

    @Test func anAgentThatReportsItsStart_endsTheLaunch() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            #expect(!fixture.store.isFollowing)
            let paneID = try Self.startAgent(fixture)
            #expect(fixture.store.isFollowing)
            fixture.store.follow(session: fixture.session, agentPanes: [paneID])
            #expect(fixture.store.launches.isEmpty)
            #expect(!fixture.store.isFollowing)
        }
    }

    @Test func anAgentThatNeverReportsItsStart_isTheCLIsStage_untilItDoes() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [], startTimeout: .milliseconds(50))
            let id = fixture.worktree.id
            let paneID = try Self.startAgent(fixture)
            // Not shown yet: its terminal is not made, and no time runs.
            fixture.store.follow(session: fixture.session, agentPanes: [])
            #expect(fixture.store.launches[id]?.phase == .starting(isLaunched: false))
            // Nothing to wait for: a stop that never comes. Three times the
            // timeout leaves a stop room to show, were one coming.
            try await Task.sleep(for: .milliseconds(150))
            #expect(fixture.store.launches[id]?.phase == .starting(isLaunched: false))
            #expect(fixture.store.launches[id]?.paneID == paneID)

            // The terminal is made: the staged command is taken.
            fixture.session.clearStagedLaunch(paneID: paneID)
            fixture.store.follow(session: fixture.session, agentPanes: [])
            #expect(fixture.store.launches[id]?.phase == .starting(isLaunched: true))
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) { fixture.store.launches[id]?.failure != nil }
            #expect(fixture.store.launches[id]?.failure?.stage == .startingCLI)

            // Signed in at last: it reports its start, and the stop goes.
            fixture.store.follow(session: fixture.session, agentPanes: [paneID])
            #expect(fixture.store.launches.isEmpty)
        }
    }

    @Test func retryingTheCLIsStage_opensAnotherTab() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [], startTimeout: .milliseconds(50))
            let id = fixture.worktree.id
            let paneID = try Self.startAgent(fixture)
            fixture.session.clearStagedLaunch(paneID: paneID)
            fixture.store.follow(session: fixture.session, agentPanes: [])
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) { fixture.store.launches[id]?.failure != nil }

            try #require(fixture.store.launches[id]?.failure?.stage == .startingCLI)
            let originalTab = try #require(fixture.session.tab(containing: paneID))
            fixture.store.retry(worktreeID: id, in: fixture.session)
            let launch = try #require(fixture.store.launches[id])
            let newPane = try #require(launch.paneID)
            let newTab = try #require(fixture.session.tab(containing: newPane))
            #expect(launch.phase == .starting(isLaunched: false))
            #expect(newPane != paneID)
            #expect(fixture.session.tab(containing: paneID)?.id == originalTab.id)
            #expect(Set(fixture.tabs.map(\.id)) == [originalTab.id, newTab.id])
            #expect(newTab.initialCommands == [newPane: "claude"])
        }
    }

    @Test func closingTheAgentsPane_forgetsTheLaunch() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            _ = try Self.startAgent(fixture)
            for tab in fixture.tabs {
                fixture.session.closeTab(tab.id)
            }
            fixture.store.follow(session: fixture.session, agentPanes: [])
            #expect(fixture.store.launches.isEmpty)
        }
    }

    @Test func anAgentInFrontThatNeverReports_waitsInItsTerminal_withoutAStop() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [], startTimeout: .milliseconds(50))
            let id = fixture.worktree.id
            fixture.store.isAgentInFront = { _, agent in agent == .claude }
            let paneID = try Self.startAgent(fixture)
            fixture.session.clearStagedLaunch(paneID: paneID)
            fixture.store.follow(session: fixture.session, agentPanes: [])
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) {
                fixture.store.launches[id]?.phase == .waitingInTerminal
            }
            #expect(fixture.store.launches[id]?.phase == .waitingInTerminal)
            #expect(fixture.store.launches[id]?.failure == nil)

            // It answered its question and reported its start.
            fixture.store.follow(session: fixture.session, agentPanes: [paneID])
            #expect(fixture.store.launches.isEmpty)
        }
    }

    @Test func aWaitingAgent_canBeDismissed() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [], startTimeout: .milliseconds(50))
            let id = fixture.worktree.id
            fixture.store.isAgentInFront = { _, _ in true }
            let paneID = try Self.startAgent(fixture)
            // Dismissing applies only to a wait in the terminal, or notes.
            fixture.store.dismiss(worktreeID: id)
            #expect(fixture.store.launches[id]?.phase == .starting(isLaunched: false))
            fixture.session.clearStagedLaunch(paneID: paneID)
            fixture.store.follow(session: fixture.session, agentPanes: [])
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) {
                fixture.store.launches[id]?.phase == .waitingInTerminal
            }
            try #require(fixture.store.launches[id]?.phase == .waitingInTerminal)
            #expect(fixture.store.launches[id]?.paneID == paneID)
            fixture.store.dismiss(worktreeID: id)
            #expect(fixture.store.launches.isEmpty)
        }
    }
}

/// What went short without stopping the worktree: said in its bar,
/// kept there once everything ran, until dismissed.
extension SessionLaunchStoreTests {
    @Test func aFetchThatFailed_isKeptAsANote_pastTheEnd_untilDismissed() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let id = fixture.worktree.id
            fixture.begin(SessionLaunchRequest(open: .shell), notes: [.fetch(.failed(start: "main", isLastFetched: false))])
            let launch = try #require(fixture.store.launches[id])
            #expect(launch.phase == .done)
            #expect(launch.notes == [.fetch(.failed(start: "main", isLastFetched: false))])
            #expect(fixture.tabs.count == 1)
            // Not a stop: no failure for the attention list.
            #expect(launch.failure == nil)
            fixture.store.dismiss(worktreeID: id)
            #expect(fixture.store.launches.isEmpty)
        }
    }

    /// An agent's start ends its launch; with a note it stays, done.
    @Test func anAgentWithANote_isDoneOnceItStarts() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let id = fixture.worktree.id
            let notes: [SessionLaunch.Note] = [.fetch(.failed(start: "main", isLastFetched: false))]
            fixture.begin(SessionLaunchRequest(open: .agent(.claude)), notes: notes)
            let paneID = try Self.startingPane(in: fixture, store: fixture.store, command: "claude")
            #expect(fixture.store.launches[id]?.notes == notes)
            for _ in 1...2 {
                fixture.store.follow(session: fixture.session, agentPanes: [paneID])
                #expect(fixture.store.launches[id]?.phase == .done)
                #expect(fixture.store.launches[id]?.notes == notes)
            }
        }
    }

    @Test func noteTexts_sayWhatWentShort() {
        let english = Locale(identifier: "en")
        let japanese = Locale(identifier: "ja")
        #expect(SessionLaunchBar.noteText(.fetch(.failed(start: "main", isLastFetched: false))).resolved(in: english)
            == "Couldn’t fetch from the remote, so the worktree starts from the local main.")
        #expect(SessionLaunchBar.noteText(.fetch(.failed(start: "main", isLastFetched: false))).resolved(in: japanese)
            == "リモートからフェッチできなかったため、ローカルの main から作成します。")
        #expect(SessionLaunchBar.noteText(.copyFailed([".env", "a.key"])).resolved(in: english) == "Couldn’t copy .env, a.key.")
        #expect(SessionLaunchBar.noteText(.copyFailed([".env"])).resolved(in: japanese) == ".env をコピーできませんでした。")
        // A list joins as the language does: no English comma in Japanese.
        #expect(SessionLaunchBar.noteText(.copyFailed([".env", "a.key"])).resolved(in: japanese) == ".env、a.key をコピーできませんでした。")
        #expect(SessionLaunchBar.noteText(.ignoredFilesNotListed).resolved(in: english)
            == "Couldn’t list the files Git ignores, so none were copied.")
        #expect(SessionLaunchBar.noteText(.ignoredFilesNotListed).resolved(in: japanese)
            == "Git が無視するファイルを一覧できなかったため、何もコピーしませんでした。")
    }

    /// The copy's limit is written in the language the note is resolved in,
    /// not the process's: 「1バイト」 in a Japanese window of a process that
    /// started in English.
    @Test func aCopyLimitNote_writesItsSizeInTheNotesLanguage() {
        let note = SessionLaunch.Note.copySkippedOverLimit([".env"], limit: 1)
        let english = SessionLaunchBar.noteText(note).resolved(in: Locale(identifier: "en"))
        let japanese = SessionLaunchBar.noteText(note).resolved(in: Locale(identifier: "ja"))
        #expect(english == "Didn’t copy .env: the files would come to more than 1 byte.")
        #expect(japanese == "合計が 1バイト を超えるため、.env はコピーしませんでした。")
    }
}

/// The files Git ignores that the project names, copied in before the
/// setup.
extension SessionLaunchStoreTests {
    /// The project's folder with `files` written in it, and the fixture's
    /// project naming `patterns` and Git listing `ignored`.
    private static func withIgnoredFiles(
        in dir: URL,
        files: [String: String],
        patterns: [String],
        ignored: [String],
        bootstrap: [BootstrapItem] = [],
        copyByteLimit: Int64 = IgnoredFileCopier.byteLimit
    ) async throws -> Fixture {
        let root = dir.appendingPathComponent("project")
        let fixture = try await Fixture.make(in: dir, bootstrap: bootstrap, copyByteLimit: copyByteLimit, rootURL: root)
        for (path, text) in files {
            try ScratchFile.write(text, to: path, in: root)
        }
        fixture.session.setProjectIgnoredFilesToCopy(fixture.project.id, to: patterns)
        fixture.git.ignored = ignored
        return fixture
    }

    @Test func theNamedIgnoredFiles_areCopiedIn_beforeTheSetup() async throws {
        try await withTempDir { dir in
            let seen = dir.appendingPathComponent("seen")
            let fixture = try await Self.withIgnoredFiles(
                in: dir,
                files: [".env": "KEY=1", "build/out.o": "x"],
                patterns: [".env"],
                ignored: [".env", "build/"],
                // The setup sees the copy already there.
                bootstrap: [.shorthand("cat .env > '\(seen.path)'")]
            )
            fixture.begin(SessionLaunchRequest(open: .shell, copiesIgnoredFiles: true))
            await pollUntil(timeout: .seconds(10)) { fixture.store.launches.isEmpty }
            let worktree = fixture.worktree.workingDirectory
            #expect(try String(contentsOf: worktree.appendingPathComponent(".env"), encoding: .utf8) == "KEY=1")
            #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("build").path))
            #expect(try String(contentsOf: seen, encoding: .utf8) == "KEY=1")
            #expect(fixture.git.operations.filter { $0 == "ls-files" } == ["ls-files"])
            #expect(fixture.store.launches.isEmpty)
            let shell = try #require(fixture.tabs.first)
            #expect(fixture.tabs.count == 1)
            #expect(shell.initialCommands.isEmpty)
        }
    }

    @Test func theFiles_areNotCopied_whenNotAskedFor() async throws {
        try await withTempDir { dir in
            let fixture = try await Self.withIgnoredFiles(in: dir, files: [".env": "KEY=1"], patterns: [".env"], ignored: [".env"])
            fixture.begin(SessionLaunchRequest(open: .shell, copiesIgnoredFiles: false))
            #expect(fixture.store.launches.isEmpty)
            #expect(!fixture.git.operations.contains("ls-files"))
            let shell = try #require(fixture.tabs.first)
            #expect(fixture.tabs.count == 1)
            #expect(shell.initialCommands.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.worktree.workingDirectory.appendingPathComponent(".env").path))
        }
    }

    /// Git could not list the ignored files: the bar says so, rather than
    /// the copy passing for one that found nothing, and the setup goes on.
    @Test func aListingThatFails_isSaid_andTheSetupGoesOn() async throws {
        try await withTempDir { dir in
            let fixture = try await Self.withIgnoredFiles(
                in: dir,
                files: [".env": "KEY=1"],
                patterns: [".env"],
                ignored: [".env"],
                bootstrap: [.shorthand("printf ran > setup-log")]
            )
            fixture.git.nextListIgnoredError = .nonZeroExit(.failure("fatal: index file corrupt"))
            fixture.begin(SessionLaunchRequest(open: .nothing, copiesIgnoredFiles: true))
            let id = fixture.worktree.id
            await pollUntil(timeout: .seconds(10)) { fixture.store.launches[id]?.phase == .done }
            try #require(fixture.store.launches[id]?.phase == .done)
            #expect(fixture.store.launches[id]?.notes == [.ignoredFilesNotListed])
            #expect(fixture.tabs.isEmpty)
            let log = fixture.worktree.workingDirectory.appendingPathComponent("setup-log")
            #expect(try String(contentsOf: log, encoding: .utf8) == "ran")
            #expect(!FileManager.default.fileExists(atPath: fixture.worktree.workingDirectory.appendingPathComponent(".env").path))
        }
    }

    @Test func copiesOverTheLimit_stopAndSaySo() async throws {
        try await withTempDir { dir in
            let fixture = try await Self.withIgnoredFiles(
                in: dir,
                files: [".env": String(repeating: "x", count: 64)],
                patterns: [".env"],
                ignored: [".env"],
                copyByteLimit: 16
            )
            fixture.begin(SessionLaunchRequest(open: .nothing, copiesIgnoredFiles: true))
            let id = fixture.worktree.id
            await pollUntil(timeout: .seconds(10)) { fixture.store.launches[id]?.phase == .done }
            try #require(fixture.store.launches[id]?.phase == .done)
            #expect(fixture.store.launches[id]?.notes == [.copySkippedOverLimit([".env"], limit: 16)])
            #expect(!FileManager.default.fileExists(atPath: fixture.worktree.workingDirectory.appendingPathComponent(".env").path))
        }
    }

    /// Holds the Git listing while the store owns the copy task. The actual
    /// copier still runs after the listing returns.
    private struct HeldListing: GitRunning {
        let reply = Gate<[String]>()
        let canceled = Recorded(false)
        let requestedRoots = Recorded<[URL]>([])
        let trace = Recorded<[String]>([])

        func listIgnored(repoRoot: URL) async throws -> [String] {
            requestedRoots.update { $0.append(repoRoot) }
            return await withTaskCancellationHandler {
                let paths = await reply.wait()
                trace.update { $0.append("listing returned") }
                return paths
            } onCancel: {
                canceled.value = true
            }
        }

        func createWorktree(repoRoot: URL, path: URL, baseBranch: String) async throws -> GitResult {
            throw CocoaError(.featureUnsupported)
        }

        func removeWorktree(repoRoot: URL, path: URL, force: Bool) async throws -> GitResult {
            throw CocoaError(.featureUnsupported)
        }

        func createBranch(repoRoot: URL, name: String, startPoint: String) async throws -> GitResult {
            throw CocoaError(.featureUnsupported)
        }

        func pruneWorktrees(repoRoot: URL) async throws -> GitResult {
            throw CocoaError(.featureUnsupported)
        }

        func listWorktrees(repoRoot: URL) async throws -> [GitWorktreeInfo] {
            throw CocoaError(.featureUnsupported)
        }

        func fetch(repoRoot: URL, remote: String, branch: String) async throws -> GitResult {
            throw CocoaError(.featureUnsupported)
        }

        func fetchRef(repoRoot: URL, remote: String, ref: String) async throws -> FetchedRef {
            throw CocoaError(.featureUnsupported)
        }

        func commitsBehind(repoRoot: URL, local: String, upstream: String) async -> Int? {
            nil
        }
    }

    private static func startCopy(in fixture: Fixture, listing: HeldListing) -> SessionLaunchStore {
        let store = SessionLaunchStore(path: { Fixture.path }, git: listing)
        store.begin(
            projectID: fixture.project.id,
            worktreeID: fixture.worktree.id,
            request: .init(open: .shell, copiesIgnoredFiles: true),
            in: fixture.session
        )
        return store
    }

    @Test func aWorktreeGoneBeforeFilesAreCopied_endsItsLaunch() async throws {
        try await withTempDir { dir in
            let fixture = try await Self.withIgnoredFiles(in: dir, files: [".env": "x"], patterns: [".env"], ignored: [])
            let listing = HeldListing()
            defer { listing.reply.open(with: [".env"]) }
            let store = Self.startCopy(in: fixture, listing: listing)
            let id = fixture.worktree.id
            try await listing.reply.waitUntilRequested()
            #expect(listing.requestedRoots.value == [fixture.project.rootURL])
            try #require(store.launches[id]?.phase == .copyingFiles)
            try FileManager.default.removeItem(at: fixture.worktree.workingDirectory)

            listing.reply.open(with: [".env"])
            await pollUntil(timeout: .seconds(10)) { store.launches.isEmpty }
            #expect(store.launches.isEmpty)
            #expect(listing.trace.value == ["listing returned"])
            #expect(fixture.tabs.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.worktree.workingDirectory.path))
        }
    }

    @Test func cancelingTheSetup_waitsForItsCopyTask() async throws {
        try await withTempDir { dir in
            let fixture = try await Self.withIgnoredFiles(in: dir, files: [".env": "x"], patterns: [".env"], ignored: [])
            let listing = HeldListing()
            defer { listing.reply.open(with: [".env"]) }
            let store = Self.startCopy(in: fixture, listing: listing)
            let id = fixture.worktree.id
            try await listing.reply.waitUntilRequested()
            try #require(store.launches[id]?.phase == .copyingFiles)
            let cancel = Task {
                await store.cancelSetup(worktreeID: id)
                listing.trace.update { $0.append("cancel returned") }
            }
            await pollUntil { listing.canceled.value }
            #expect(listing.canceled.value)
            #expect(listing.trace.value.isEmpty)
            #expect(store.launches.isEmpty)

            listing.reply.open(with: [".env"])
            await cancel.value
            #expect(listing.trace.value == ["listing returned", "cancel returned"])
            #expect(fixture.tabs.isEmpty)
            let destination = fixture.worktree.workingDirectory.appendingPathComponent(".env")
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }
}

/// The agent's executable as the new worktree sheet found it
/// (`SessionLaunchRequest.executable`): staged for its one pane, cleared
/// with the staged command, and never saved.
extension SessionLaunchStoreTests {
    private static func open(
        _ request: SessionLaunchRequest,
        store: SessionLaunchStore,
        session: WorkspaceSession,
        project: Project
    ) -> UUID? {
        store.open(request, in: .project(project.id), session: session, window: session.primaryWindowID, intent: .person, selects: true)
    }

    @Test func theSheetsExecutable_reachesItsPanesShell_andIsGoneOnceThePaneIsMade() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let store = SessionLaunchStore(path: { Fixture.path }, git: FakeGit())
        let found = "/Users/someone/.local/share/mise/installs/node/22/bin/codex"
        let paneID = try #require(Self.open(
            SessionLaunchRequest(open: .agent(.codex), executable: found),
            store: store,
            session: session,
            project: project
        ))
        let staged = try #require(PaneHostRepresentable.launch(session: session, paneID: paneID).staged)
        #expect(staged.command == "codex")
        #expect(staged.agentExecutable == AgentInstallation(kind: .codex, executable: found))
        #expect(staged.environment["WEIR_FOUND_CODEX"] == found)
        #expect(staged.environment[InitialPromptFile.environmentKey] == nil)
        #expect(staged.environment["WEIR_FOUND_CLAUDE"] == nil)

        // Saved and read back, as at the next launch, the command stays
        // (it is cleared only once its pane is made) and the path does
        // not: a restored pane searches afresh.
        let tab = try #require(session.tab(containing: paneID))
        let restored = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(tab))
        #expect(restored.initialCommands[paneID] == "codex")
        #expect(restored.initialAgentExecutables.isEmpty)

        session.clearStagedLaunch(paneID: paneID)
        #expect(session.tab(containing: paneID)?.initialAgentExecutables.isEmpty == true)
        #expect(PaneHostRepresentable.launch(session: session, paneID: paneID).staged == nil)
    }

    @Test func anAgentWithoutAnExecutable_isLeftToItsShimsSearch_andAShellStagesNothing() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let store = SessionLaunchStore(path: { Fixture.path }, git: FakeGit())
        let searching = try #require(Self.open(
            SessionLaunchRequest(open: .agent(.codex)),
            store: store,
            session: session,
            project: project
        ))
        let launch = try #require(session.stagedLaunch(paneID: searching))
        #expect(launch.command == "codex")
        #expect(launch.environment.isEmpty)
        let shell = try #require(Self.open(SessionLaunchRequest(open: .shell), store: store, session: session, project: project))
        #expect(session.stagedLaunch(paneID: shell) == nil)
        let before = session.tabs(in: .project(project.id)).map(\.id)
        #expect(Self.open(SessionLaunchRequest(open: .nothing), store: store, session: session, project: project) == nil)
        #expect(before.count == 2)
        #expect(session.tabs(in: .project(project.id)).map(\.id) == before)
    }
}
