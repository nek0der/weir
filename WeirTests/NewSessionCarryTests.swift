// NewSessionCarryTests.swift
// Weir — the new worktree sheet's carry of the shown worktree's uncommitted changes: its rules, its checkbox, and Create with real git.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct UncommittedCarryRulesTests {
    @Test(arguments: [
        (false, true, true, true, UncommittedCarryRefusal.noCommit as UncommittedCarryRefusal?),
        (true, true, true, false, .operationInProgress),
        (true, false, true, false, .unsupportedCheckout),
        (true, false, false, true, .unsupportedCheckout),
        (true, false, true, true, .unsupportedCheckout),
        (true, false, false, false, nil)
    ])
    func theFirstRefusal_inOrder(
        hasCommit: Bool, operation: Bool, sparse: Bool, splitIndex: Bool, expected: UncommittedCarryRefusal?
    ) {
        #expect(UncommittedCarryRules.refusal(
            hasCommit: hasCommit, isOperationInProgress: operation, usesSparseCheckout: sparse, usesSplitIndex: splitIndex
        ) == expected)
    }

    @Test(arguments: [
        ("", 0),
        ("MM a.txt\0R  new.txt\0old.txt\0?? n.txt\0 D gone\0", 4),
        (" C copy\0from\0", 1),
        ("C  copied\0R  original-looking-like-a-status\0?? untracked\0", 2),
        (" R renamed\0C  original-looking-like-a-status\0", 1),
        ("?? :160000 ordinary.txt\0", 1)
    ])
    func theCount_takesARenameAsOneFile(porcelain: String, expected: Int) {
        #expect(UncommittedCarryRules.changedFileCount(porcelain: porcelain) == expected)
    }

    /// A path above or below one with something else on disk is left
    /// alone too, through a chain of them: putting `a/b` back would drop
    /// the entry `a`. A path with nothing on disk stops none.
    @Test func theOwnPaths_leaveAloneWhatIsAboveOrBelowAPathLeftAlone() {
        let written = ["a", "a/b", "a/b/c", "x.txt", "a2"]
        let foreign: (String) -> (String) -> UncommittedCarryRules.WrittenPath = { other in
            { $0 == other ? .foreign : .ours }
        }
        #expect(UncommittedCarryRules.ownPaths(written, state: foreign("a")) == ["x.txt", "a2"])
        #expect(UncommittedCarryRules.ownPaths(written, state: foreign("a/b/c")) == ["x.txt", "a2"])
        #expect(UncommittedCarryRules.ownPaths(["d", "d/e", "d/f"], state: foreign("d/e")) == [])
        #expect(UncommittedCarryRules.ownPaths(written) { _ in .ours } == written)
        #expect(UncommittedCarryRules.ownPaths(written) { _ in .foreign } == [])
        #expect(UncommittedCarryRules.ownPaths(["a", "a/b", "a/c"]) { $0 == "a/c" ? .absent : .ours } == ["a", "a/b"])
    }

    /// Paths that a volume may take for one name are grouped: those that
    /// differ only in case when the volume ignores case, and those that
    /// differ only in Unicode normalization on any volume.
    @Test func possiblySharedPaths_groupCaseAndNormalizationVariants() {
        let composed = "caf\u{E9}.txt"
        let decomposed = "cafe\u{301}.txt"
        let paths = ["a.txt", "A.txt", "dir/a", "DIR/a", "dir/b", composed, decomposed]
        func bytes(_ groups: [[String]]) -> Set<Set<[UInt8]>> {
            Set(groups.map { Set($0.map { Array($0.utf8) }) })
        }

        let folded = UncommittedCarryRules.possiblySharedPaths(paths, foldsCase: true)
        #expect(folded.count == 3)
        #expect(bytes(folded) == bytes([["A.txt", "a.txt"], ["DIR/a", "dir/a"], [composed, decomposed]]))
        let caseSensitive = UncommittedCarryRules.possiblySharedPaths(paths, foldsCase: false)
        #expect(caseSensitive.count == 1)
        #expect(bytes(caseSensitive) == bytes([[composed, decomposed]]))
        #expect(UncommittedCarryRules.possiblySharedPaths(["a.txt", "b.txt"], foldsCase: true).isEmpty)
    }

    @Test(arguments: [
        (":100644 100644 aaa bbb M\0a.txt\0", false),
        (":100644 100644 aaa bbb M\0a.txt\0:000000 160000 000 ccc A\0vendor/inner\0", true),
        (":160000 000000 aaa 000 D\0sub\0", true),
        (":160000 160000 ddd eee M\0sub\0", true),
        (":100644 100644 aaa bbb M\0160000\0", false),
        (":100644 100644 aaa bbb M\0:160000 harmless.txt\0", false)
    ])
    func aGitlink_isFoundOnEitherSide(rawDiff: String, touchesGitlinks: Bool) {
        #expect(UncommittedCarryRules.touchesGitlinks(rawDiff: rawDiff) == touchesGitlinks)
    }

    @Test func theConflictedPaths_areTheLinesAfterTheTree() {
        #expect(UncommittedCarryRules.conflictPaths(mergeTreeOutput: "abc123\na.txt\nb.txt\na.txt\n\nmessages") == ["a.txt", "b.txt"])
        #expect(UncommittedCarryRules.conflictPaths(mergeTreeOutput: "abc123\n").isEmpty)
    }

    @Test func anOldGit_isToldApart() {
        #expect(UncommittedCarryRules.isUnknownOption(exitCode: 129, stderr: ""))
        #expect(UncommittedCarryRules.isUnknownOption(exitCode: 1, stderr: "error: unknown option `merge-base'"))
        #expect(UncommittedCarryRules.isUnknownOption(exitCode: 1, stderr: "error: UNKNOWN OPTION `attr-source'"))
        #expect(!UncommittedCarryRules.isUnknownOption(exitCode: 128, stderr: "fatal: bad object"))
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NewSessionCarryTests {
    private typealias Fixture = NewSessionActionsTests.Fixture

    // MARK: - The checkbox

    @Test(arguments: [3, nil] as [Int?])
    func theFolderShown_withChanges_canBeCarried_andIsOffUntilAskedFor(_ count: Int?) async throws {
        try await withTempDir { dir in
            let fixture = Fixture(directory: dir)
            fixture.changedFiles = count
            var model = try await fixture.load()
            let source = try #require(model.context.carrySource)
            #expect(source.root == fixture.project.rootURL)
            #expect(source.name == "main")
            #expect(source.changedFiles == count)
            #expect(model.canCarryChanges)
            #expect(model.plan?.carry == nil, "off until asked for")
            model.carriesChanges = true
            #expect(model.plan?.carry == source)
            let line = model.carryLine(locale: Locale(identifier: "en"))
            #expect(line.hasPrefix("3 files uncommitted · ") == (count != nil))
            #expect(model.choices == NewSessionModel.initialChoices(
                fixture.settings.settings.newSession,
                forProjectAt: fixture.project.rootURL,
                installed: model.context.installedAgents
            ), "the carry is not among the choices kept")
        }
    }

    @Test func aRowWithNothingToCarry_isOff_andSaysSo() async throws {
        try await withTempDir { dir in
            let fixture = Fixture(directory: dir)
            fixture.changedFiles = 0
            var model = try await fixture.load()
            model.carriesChanges = true
            #expect(!model.canCarryChanges)
            #expect(model.plan?.carry == nil)
            #expect(model.carryLine(locale: Locale(identifier: "ja")) == "未コミットの変更はありません")
        }
    }

    /// A header's ＋ on another project: the window shows no row of it, so
    /// nothing of this window's row goes into that project's worktree.
    @Test func anotherProjectsSheet_carriesNothing() async throws {
        try await withTempDir { dir in
            let fixture = Fixture(directory: dir)
            fixture.changedFiles = 3
            let other = fixture.session.addOrActivateProject(
                rootURL: WorkspaceSessionFixture.projectRootURL("other"),
                suggestedName: "other"
            )
            var model = try #require(await NewSessionActions.load(
                NewSessionSheetRequest(projectID: other.id),
                window: fixture.window,
                stores: fixture.stores
            ))
            #expect(model.context.carrySource == nil)
            #expect(!model.canCarryChanges)
            model.carriesChanges = true
            let plan = try #require(model.plan)
            #expect(plan.carry == nil)
        }
    }

    // MARK: - Create, with real git

    /// A repository's project in a window, its stores with real git, and
    /// the form, asked to carry, with nothing to open or set up.
    @MainActor
    private struct Form {
        let session: WorkspaceSession
        let windows: WindowRegistry
        let stores: NewSessionStores
        var model: NewSessionModel
        let request: NewSessionSheetRequest

        func create() async -> NewSessionActions.CreateOutcome {
            await NewSessionActions.create(model, request: request, window: windows.primary, stores: stores)
        }
    }

    private static func form(_ repo: TempGitRepo, settings: URL) async throws -> Form {
        let session = WorkspaceSession()
        let project = session.addOrActivateProject(rootURL: repo.url, suggestedName: "repo")
        session.setActiveContainer(.project(project.id))
        let windows = WindowRegistry(primary: session.primarySelection)
        var stores = NewSessionStores(
            session: session,
            launches: SessionLaunchStore(path: { nil }),
            settingsStore: SettingsStore(directory: settings)
        )
        stores.readFacts = { root, _ in await NewSessionFacts.readGit(root: root) }
        stores.remembersChoices = false
        let request = NewSessionSheetRequest(projectID: project.id)
        var model = try #require(await NewSessionActions.load(request, window: windows.primary, stores: stores))
        await model.setCarryCount(NewSessionActions.countCarryChanges(for: model, stores: stores))
        model.open = .nothing
        model.runsSetup = false
        model.fetches = false
        model.carriesChanges = true
        return Form(session: session, windows: windows, stores: stores, model: model, request: request)
    }

    @Test(arguments: ["b.txt", ":160000 harmless.txt"])
    func create_movesTheChangesIntoTheNewWorktree(untrackedPath: String) async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try repo.write("one\n", to: "a.txt")
        try await repo.git(["add", "a.txt"])
        try await repo.git(["commit", "-q", "-m", "a"])
        try repo.write("two\n", to: "a.txt")
        try repo.write("new\n", to: untrackedPath)

        try await withTempDir { dir in
            var form = try await Self.form(repo, settings: dir)
            #expect(form.model.context.carrySource?.changedFiles == 2)
            form.model.setBranchName("feat/moved")

            try #require(await form.create() == .created(branch: "feat/moved"))

            let project = form.session.project(form.request.projectID)
            let worktree = try #require(project?.worktrees.first { $0.gitRef?.branchName == "feat/moved" })
            #expect(try String(contentsOf: worktree.workingDirectory.appendingPathComponent("a.txt"), encoding: .utf8) == "two\n")
            #expect(try String(contentsOf: worktree.workingDirectory.appendingPathComponent(untrackedPath), encoding: .utf8) == "new\n")
            #expect(try await repo.git(["status", "--porcelain"]).isEmpty)
            // A move that went as asked leaves no note to close: the launch
            // ends and is gone, where one with a note stays to be read.
            let launches = form.stores.launches
            await pollUntil { launches.launches[worktree.id] == nil }
            #expect(launches.launches[worktree.id] == nil)
        }
    }

    @Test(arguments: [false, true])
    func create_refusesARealGitlinkAdditionOrDeletion(isDeletion: Bool) async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let head = try await repo.git(["rev-parse", "HEAD"])
        let path = "vendor/submodule"
        try await repo.git(["update-index", "--add", "--cacheinfo", "160000,\(head),\(path)"])
        if isDeletion {
            try await repo.git(["commit", "-q", "-m", "track the gitlink"])
            try await repo.git(["update-index", "--force-remove", path])
        }
        let staged = try await repo.git(["diff", "--cached", "--raw", "--no-renames"])
        #expect(staged.hasPrefix(isDeletion ? ":160000 000000 " : ":000000 160000 "))

        try await withTempDir { dir in
            var form = try await Self.form(repo, settings: dir)
            form.model.setBranchName("feat/gitlink")
            let target = try #require(form.model.plan?.path)
            let outcome = await form.create()
            guard case let .failed(message, madeBranch) = outcome else {
                Issue.record("Create did not refuse the gitlink: \(outcome)")
                return
            }
            #expect(madeBranch == nil)
            #expect(message.resolved(in: Locale(identifier: "en")).contains("main has changes in a submodule"))
            #expect(!FileManager.default.fileExists(atPath: target.path))
            #expect(try await repo.git(["diff", "--cached", "--raw", "--no-renames"]) == staged)
        }
    }

    /// Changes that conflict with the start stop Create on the sheet:
    /// nothing is made, no branch, and the source keeps every change.
    @Test func create_withChangesThatConflict_makesNothing_andLeavesTheSource() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try repo.write("one\n", to: "a.txt")
        try await repo.git(["add", "a.txt"])
        try await repo.git(["commit", "-q", "-m", "a"])
        // A branch whose commit changes the same line, checked out nowhere.
        let theirs = try await repo.addLinkedWorktree(branch: "theirs-wt")
        try Data("theirs\n".utf8).write(to: theirs.appendingPathComponent("a.txt"))
        try await TempGitRepo.git(["commit", "-q", "-am", "theirs"], in: theirs)
        try await repo.git(["branch", "theirs-copy", "theirs-wt"])
        try repo.write("mine\n", to: "a.txt")
        let before = try await repo.git(["status", "--porcelain"])
        let worktrees = try await repo.git(["worktree", "list", "--porcelain"])
        let refs = try await repo.git(["show-ref"])

        try await withTempDir { dir in
            var form = try await Self.form(repo, settings: dir)
            form.model.source = .existingBranch
            form.model.existingBranch = "theirs-copy"
            let target = try #require(form.model.plan?.path)
            #expect(!FileManager.default.fileExists(atPath: target.path))

            let outcome = await form.create()

            guard case let .failed(message, madeBranch) = outcome else {
                Issue.record("the create did not fail: \(outcome)")
                return
            }
            #expect(madeBranch == nil)
            let said = message.resolved(in: Locale(identifier: "en"))
            #expect(said.contains("a.txt") && said.contains("main is unchanged"))
            #expect(form.session.project(form.request.projectID)?.worktrees.contains { $0.gitRef?.branchName == "theirs-copy" } == false)
            #expect(try await repo.git(["status", "--porcelain"]) == before)
            #expect(try await repo.git(["worktree", "list", "--porcelain"]) == worktrees)
            #expect(try await repo.git(["show-ref"]) == refs)
            #expect(!FileManager.default.fileExists(atPath: target.path))
            #expect(try String(contentsOf: repo.url.appendingPathComponent("a.txt"), encoding: .utf8) == "mine\n")
        }
    }
}
