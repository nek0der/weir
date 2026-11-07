// SidebarRowCheckoutTests.swift
// Weir — a labeled row shows its branch, or its folder with none, wherever it is named.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct SidebarRowCheckoutTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    /// This holds a project "weir" with one worktree in the folder
    /// "login-redesign" on the branch "feat/login", and that worktree's row.
    private struct Fixture {
        let session: WorkspaceSession
        let project: Project
        let worktree: ContainerID
    }

    private static func project() -> Fixture {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let index = session.projects.firstIndex { $0.id == project.id } ?? 0
        let worktree = Worktree(
            label: "login-redesign",
            workingDirectory: URL(fileURLWithPath: "/tmp/login-redesign"),
            gitRef: GitRef(branchName: "feat/login"),
            origin: .gitWorktree
        )
        session.projects[index].worktrees = [worktree]
        return Fixture(
            session: session,
            project: session.projects[index],
            worktree: .worktree(projectID: project.id, worktreeID: worktree.id)
        )
    }

    private static func model(_ session: WorkspaceSession, _ project: Project, locale: Locale = english) -> SessionSidebarModel {
        SessionSidebarModel(
            project: project,
            session: session,
            window: session.primaryWindowID,
            queue: AttentionQueue(),
            runtimes: [],
            approvals: ApprovalLedger(),
            pullRequest: { _ in nil },
            gitFacts: { _ in nil },
            locale: locale
        )
    }

    /// Makes a worktree's row labeled `name`, showing `checkout` (whose
    /// full name is `fullCheckout`, when a folder was shortened), with
    /// `fact`. The checkout is the branch unless `isBranch` says it is a
    /// folder, whose row then has no branch.
    private static func row(
        name: String = "Login work",
        checkout: String?,
        fullCheckout: String? = nil,
        isBranch: Bool = true,
        fact: SessionRowFact.Input = .init(),
        container: ContainerID = .worktree(projectID: UUID(), worktreeID: UUID()),
        locale: Locale = english
    ) -> SessionSidebarModel.Row {
        var input = SessionSidebarModel.RowInput.test(container: container, name: name, fact: fact)
        input.checkout = checkout.map { RowCheckout(name: fullCheckout ?? $0, shown: $0, isBranch: isBranch) }
        input.label = checkout == nil ? nil : name
        input.branch = isBranch ? "feat/login" : nil
        return .test(input, locale: locale)
    }

    /// Returns the whole second line as it reads: the lead, then the fact it
    /// shows.
    private static func lineTwo(_ row: SessionSidebarModel.Row, locale: Locale = english) -> String {
        let fact = SessionRowFactText.current(row, now: .now, locale: locale)
        return SessionRowFactText.lineLead(row, fact: fact, locale: locale) + (row.showsFact ? fact : "")
    }

    private static let idleAgent = SessionRowFact.Input(agents: [.init(provider: .claude, state: .idle, detail: nil)])

    // MARK: - The rule

    /// A label stands for the row on its first line, so the branch goes
    /// beside it; no other name needs one.
    @Test func onlyAManualLabel_showsADistinctBranchOrFolder() {
        let label = RowName(text: "Login work", source: .manual)
        #expect(label.checkoutBeside(branch: "feat/login", folder: "login-redesign")
            == RowCheckout(name: "feat/login", shown: "feat/login", isBranch: true))
        #expect(RowName(text: "Feat/Login", source: .manual).checkoutBeside(branch: "feat/login", folder: "login-redesign") == nil)
        #expect(RowName(text: "Add tests", source: .conversation).checkoutBeside(branch: "feat/login", folder: "login-redesign") == nil)
        #expect(RowName(text: "feat/login", source: .branch).checkoutBeside(branch: "feat/login", folder: "login-redesign") == nil)
        #expect(RowName(text: "login-redesign", source: .folder).checkoutBeside(branch: nil, folder: "login-redesign") == nil)

        #expect(label.checkoutBeside(branch: nil, folder: "login-redesign")
            == RowCheckout(name: "login-redesign", shown: "login-redesign", isBranch: false))
        #expect(label.checkoutBeside(branch: "", folder: "login-redesign")
            == RowCheckout(name: "login-redesign", shown: "login-redesign", isBranch: false))
        #expect(RowName(text: "Login-Redesign", source: .manual).checkoutBeside(branch: nil, folder: "login-redesign") == nil)
        #expect(label.checkoutBeside(branch: nil, folder: nil) == nil)
    }

    /// A worktree Weir made beside the project starts with the project's
    /// folder name and a hyphen. That start is the same on every worktree of
    /// the project, so the row shows only the rest.
    @Test func theProjectsPrefix_isLeftOff_theFolderShown() {
        #expect(RowCheckout.shortened("duesmith-fix-tax-rounding", repository: "duesmith") == "fix-tax-rounding")
        #expect(RowCheckout.shortened("DueSmith-fix-tax-rounding", repository: "duesmith") == "fix-tax-rounding", "without case")
        #expect(RowCheckout.shortened("pdf-worker-fix-page-breaks", repository: "duesmith") == "pdf-worker-fix-page-breaks")
        #expect(RowCheckout.shortened("duesmithy-fix", repository: "duesmith") == "duesmithy-fix", "a longer word is not the prefix")
        #expect(RowCheckout.shortened("duesmith", repository: "duesmith") == "duesmith", "the project's own name is kept")
        #expect(RowCheckout.shortened("duesmith-", repository: "duesmith") == "duesmith-", "nothing would be left")
        #expect(RowCheckout.shortened("fix-tax-rounding", repository: nil) == "fix-tax-rounding")

        let name = RowName(text: "Tax rounding", source: .manual)
        #expect(name.checkoutBeside(branch: nil, folder: "duesmith-fix-tax-rounding", repository: "duesmith")
            == RowCheckout(name: "duesmith-fix-tax-rounding", shown: "fix-tax-rounding", isBranch: false))
        // A label that is the shortened folder would only say it again.
        #expect(RowName(text: "Fix-Tax-Rounding", source: .manual)
            .checkoutBeside(branch: nil, folder: "duesmith-fix-tax-rounding", repository: "duesmith") == nil)
    }

    /// The session gives a labeled worktree its branch, and one with no
    /// branch its folder shortened by its project's folder name.
    @Test func theSession_givesALabeledWorktree_itsBranch_orItsShortenedFolder() throws {
        let rootURL = WorkspaceSessionFixture.projectRootURL("parent").appendingPathComponent("duesmith")
        let (session, project) = WorkspaceSessionFixture.withProject(name: "Duesmith App", rootURL: rootURL)
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        let repository = project.rootURL.lastPathComponent
        #expect(repository == "duesmith")
        #expect(project.name == "Duesmith App")
        let parent = project.rootURL.deletingLastPathComponent()
        let branched = Worktree(
            label: "tax",
            workingDirectory: parent.appendingPathComponent("\(repository)-fix-tax-rounding"),
            gitRef: GitRef(branchName: "fix/tax-rounding"),
            origin: .gitWorktree
        )
        let detached = Worktree(
            label: "bisect",
            workingDirectory: parent.appendingPathComponent("\(repository)-bisect"),
            gitRef: GitRef(branchName: nil, headSHA: "abc"),
            origin: .gitWorktree
        )
        session.projects[index].worktrees = [branched, detached]
        let row = ContainerID.worktree(projectID: project.id, worktreeID: branched.id)
        session.renameRow(row, to: "Tax rounding", runtimes: [])
        #expect(session.rowCheckout(of: row) == RowCheckout(name: "fix/tax-rounding", shown: "fix/tax-rounding", isBranch: true))
        session.renameRow(row, to: "FIX/tax-rounding", runtimes: [])
        #expect(session.rowCheckout(of: row) == nil, "a label that is the branch")

        let bisect = ContainerID.worktree(projectID: project.id, worktreeID: detached.id)
        session.renameRow(bisect, to: "Find the regression", runtimes: [])
        #expect(session.rowCheckout(of: bisect) == RowCheckout(name: "duesmith-bisect", shown: "bisect", isBranch: false))
        session.renameRow(bisect, to: "BISECT", runtimes: [])
        #expect(session.rowCheckout(of: bisect) == nil)
    }

    /// A worktree with no branch is named by its folder, and a newline in
    /// that folder shows rather than running its two lines together.
    @Test func theSession_namesAWorktreeWithANewlineInItsFolder_withTheNewlineShown() throws {
        let rootURL = WorkspaceSessionFixture.projectRootURL("parent").appendingPathComponent("duesmith")
        let (session, project) = WorkspaceSessionFixture.withProject(name: "duesmith", rootURL: rootURL)
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        let detached = Worktree(
            label: "bisect",
            workingDirectory: project.rootURL.deletingLastPathComponent().appendingPathComponent("duesmith-bisect\nold"),
            gitRef: GitRef(branchName: nil, headSHA: "abc"),
            origin: .gitWorktree
        )
        session.projects[index].worktrees = [detached]
        let row = ContainerID.worktree(projectID: project.id, worktreeID: detached.id)
        #expect(session.rowName(of: row)?.text == "duesmith-bisect\u{240A}old")
        session.renameRow(row, to: "Find the regression", runtimes: [])
        #expect(session.rowCheckout(of: row) == RowCheckout(
            name: "duesmith-bisect\u{240A}old",
            shown: "bisect\u{240A}old",
            isBranch: false
        ))
    }

    /// The project's folder row, labeled, shows its branch; with no branch
    /// known, its folder whole, unless that is the project's name, which
    /// the header says.
    @Test func theSession_givesALabeledFolderRow_itsBranch_orItsFolder() throws {
        let rootURL = WorkspaceSessionFixture.projectRootURL("parent").appendingPathComponent("duesmith")
        let (session, project) = WorkspaceSessionFixture.withProject(name: "duesmith", rootURL: rootURL)
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        let root = ContainerID.project(project.id)
        session.renameRow(root, to: "Main checkout", runtimes: [])

        session.projects[index].mainBranchName = "main"
        #expect(session.rowCheckout(of: root) == RowCheckout(name: "main", shown: "main", isBranch: true))

        session.projects[index].mainBranchName = nil
        session.projects[index].name = "Duesmith App"
        #expect(session.rowCheckout(of: root) == RowCheckout(name: "duesmith", shown: "duesmith", isBranch: false))
        session.projects[index].name = "DUESMITH"
        #expect(session.rowCheckout(of: root) == nil)
    }

    /// The session gives the checkout for a row labeled on the row itself
    /// or by its first tab, and none for a row it names by its branch or
    /// the scratch row.
    @Test func theSession_givesTheCheckout_ofEveryLabeledRow() {
        let fixture = Self.project()
        let (session, worktree) = (fixture.session, fixture.worktree)
        let checkout = RowCheckout(name: "feat/login", shown: "feat/login", isBranch: true)
        #expect(session.rowName(of: worktree) == RowName(text: "feat/login", source: .branch))
        #expect(session.rowCheckout(of: worktree) == nil)
        #expect(session.rowCheckout(of: .loose) == nil)

        session.renameRow(worktree, to: "Login work", runtimes: [])
        #expect(session.rowName(of: worktree) == RowName(text: "Login work", source: .manual))
        #expect(session.rowCheckout(of: worktree) == checkout)
        session.renameRow(worktree, to: "", runtimes: [])

        let unnamed = session.openTab(container: worktree)
        let named = session.openTab(container: worktree)
        #expect(session.tabs(in: worktree).map(\.id) == [unnamed.id, named.id])
        session.update(named.id) { $0.titleOverride = "Tab name" }
        #expect(session.rowName(of: worktree) == RowName(text: "Tab name", source: .manual))
        #expect(session.rowCheckout(of: worktree) == checkout)
    }

    /// The rename field starts from the row's label, and empty on a row
    /// with none, so the branch is never what it edits.
    @Test func theRenameField_startsFromTheLabel_andEmptyWithoutOne() throws {
        let fixture = Self.project()
        let (session, project, worktree) = (fixture.session, fixture.project, fixture.worktree)
        #expect(session.rowName(of: worktree)?.label == nil)
        let unlabeled = try #require(Self.model(session, project).rows.first { $0.id == worktree })
        #expect(unlabeled.name == "feat/login")
        #expect(unlabeled.label == nil)

        session.renameRow(worktree, to: "Login work", runtimes: [])
        #expect(session.rowName(of: worktree)?.label == "Login work")
        let labeled = try #require(Self.model(session, project).rows.first { $0.id == worktree })
        #expect(labeled.label == "Login work")

        session.renameRow(worktree, to: "", runtimes: [])
        let projectIndex = try #require(session.projects.firstIndex { $0.id == project.id })
        let worktreeIndex = try #require(session.projects[projectIndex].worktrees.firstIndex { $0.id == worktree.worktreeID })
        session.projects[projectIndex].worktrees[worktreeIndex].gitRef = GitRef(branchName: nil, headSHA: "abc")
        let tab = session.openTab(container: worktree)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        session.update(tab.id) {
            $0.conversationName = ConversationName(
                name: "Add tests",
                provider: .claude,
                paneID: paneID,
                conversationID: "c",
                startedAt: nil
            )
        }
        #expect(session.rowName(of: worktree) == RowName(text: "Add tests", source: .conversation))
        let conversational = try #require(Self.model(session, session.projects[projectIndex]).rows.first { $0.id == worktree })
        #expect(conversational.name == "Add tests")
        #expect(conversational.label == nil)
        #expect(conversational.checkout == nil)
        // Submitting the empty field it starts with renames nothing.
        #expect(InlineRenameField.submission(draft: "", startedFrom: "", submitsEmptyName: true) == nil)
    }

    /// Remove Label clears the label as an empty field does: the row goes
    /// by its branch again, with nothing beside it.
    @Test func removingTheLabel_handsTheRowBackToItsBranch() throws {
        let fixture = Self.project()
        let (session, project, worktree) = (fixture.session, fixture.project, fixture.worktree)
        session.renameRow(worktree, to: "Login work", runtimes: [])
        let labeled = try #require(Self.model(session, project).rows.first { $0.id == worktree })
        #expect(labeled.label == "Login work")
        #expect(labeled.checkout == RowCheckout(name: "feat/login", shown: "feat/login", isBranch: true))

        session.renameRow(worktree, to: "", runtimes: [])
        #expect(session.rowName(of: worktree) == RowName(text: "feat/login", source: .branch))
        let row = try #require(Self.model(session, project).rows.first { $0.id == worktree })
        #expect(row.label == nil)
        #expect(row.checkout == nil)
    }

    // MARK: - The second line

    @Test func aLabeledRow_startsItsSecondLineWithItsBranch_beforeAFactThatSaysMore() {
        let row = Self.row(checkout: "feat/login", fact: .init(agents: Self.idleAgent.agents, uncommittedFiles: 3))
        #expect(row.showsFact)
        let lead = SessionRowFactText.lineLead(row, fact: row.factText, locale: Self.english)
        #expect(lead == "feat/login · ")
        #expect(!lead.contains(row.factText))
        #expect(Self.lineTwo(row) == "feat/login · 3 files uncommitted")

        let japanese = Self.row(
            checkout: "feat/login",
            fact: .init(agents: Self.idleAgent.agents, uncommittedFiles: 3),
            locale: Self.japanese
        )
        #expect(Self.lineTwo(japanese, locale: Self.japanese) == "feat/login · 未コミット 3 ファイル")

        let pullRequest = Self.row(checkout: "feat/login", fact: .init(pullRequest: .init(number: 12, state: .open, isDraft: false)))
        #expect(Self.lineTwo(pullRequest) == "feat/login · PR #12 · Open")

        let tool = Self.row(
            checkout: "feat/login",
            fact: .init(agents: [.init(provider: .claude, state: .running, detail: "Bash: swift test")])
        )
        #expect(Self.lineTwo(tool) == "feat/login · Bash: swift test")
    }

    /// "Idle" and "Running" only name what the glyph shows: a labeled row
    /// shows its branch alone.
    @Test func aLabeledRow_dropsAFactThatOnlyRepeatsItsState() {
        let idle = Self.row(checkout: "feat/login", fact: Self.idleAgent)
        #expect(!idle.showsFact)
        #expect(Self.lineTwo(idle) == "feat/login")

        let running = Self.row(checkout: "feat/login", fact: .init(agents: [.init(provider: .claude, state: .running, detail: nil)]))
        #expect(running.factText == "Running")
        #expect(Self.lineTwo(running) == "feat/login")

        let shell = Self.row(checkout: "feat/login")
        #expect(Self.lineTwo(shell) == "feat/login")

        #expect(SessionRowFact.repeatsGlyph(.approval(nil)))
        #expect(SessionRowFact.repeatsGlyph(.stopped(.error(nil))))
        #expect(SessionRowFact.repeatsGlyph(.unread(.pending)))
        #expect(SessionRowFact.repeatsGlyph(.prompt(.approval(PromptApproval(tool: nil, action: .command, subject: nil, detail: nil)))))
        #expect(SessionRowFact.repeatsGlyph(.prompt(.question(detail: nil))))
        #expect(SessionRowFact.repeatsGlyph(.prompt(.unclassified(detail: nil))))
        #expect(!SessionRowFact.repeatsGlyph(.prompt(.unclassified(detail: "Proceed?"))))
        #expect(!SessionRowFact.repeatsGlyph(.stopped(.usageLimit(UsageLimit(resetAt: nil, window: "five_hour")))))
        #expect(!SessionRowFact.repeatsGlyph(.stopped(.processExited)))
        #expect(!SessionRowFact.repeatsGlyph(.unread(.unchanged)))
        #expect(!SessionRowFact.repeatsGlyph(.compacting))
    }

    /// A row the person did not label keeps its line as it was, "Idle"
    /// included, so every row keeps two lines.
    @Test func anUnlabeledRow_keepsItsLine() {
        let row = Self.row(name: "feat/login", checkout: nil, fact: Self.idleAgent)
        #expect(row.showsFact)
        #expect(SessionRowFactText.lineLead(row, fact: row.factText, locale: Self.english).isEmpty)
        #expect(Self.lineTwo(row) == "Idle")
    }

    /// A label that is the branch would only be said again.
    @Test func aLabelThatIsTheBranch_showsNoCheckout() throws {
        let fixture = Self.project()
        let (session, project, worktree) = (fixture.session, fixture.project, fixture.worktree)
        session.renameRow(worktree, to: "Feat/Login", runtimes: [])
        let row = try #require(Self.model(session, project).rows.first { $0.id == worktree })
        #expect(row.checkout == nil)
        #expect(Self.lineTwo(row) == "Idle")
    }

    @Test func theLabeledMainCheckout_showsTheBranchOrFolder_inPlaceOfIdle() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(
            name: "Duesmith App",
            rootURL: WorkspaceSessionFixture.projectRootURL("parent").appendingPathComponent("duesmith")
        )
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        let root = ContainerID.project(project.id)
        let unnamed = try #require(Self.model(session, project).rows.first { $0.id == root })
        #expect(Self.lineTwo(unnamed) == "Idle")

        session.renameRow(root, to: "Main checkout", runtimes: [])
        let detached = try #require(Self.model(session, session.projects[index]).rows.first { $0.id == root })
        #expect(detached.name == "Main checkout")
        #expect(Self.lineTwo(detached) == "duesmith")
        #expect(SessionRowFactText.spokenLabel(for: detached, projectName: "Duesmith App", now: .now, locale: Self.english)
            == "Shell, Main checkout, Folder duesmith, Duesmith App, Repository folder")

        session.projects[index].mainBranchName = "main"
        let branched = try #require(Self.model(session, session.projects[index]).rows.first { $0.id == root })
        #expect(Self.lineTwo(branched) == "main")
        #expect(SessionRowFactText.spokenLabel(for: branched, projectName: "Duesmith App", now: .now, locale: Self.english)
            == "Shell, Main checkout, Branch main, Duesmith App, Repository folder")
    }

    // MARK: - Tooltip and VoiceOver

    /// The line shows a folder shortened; the tooltip and VoiceOver say it
    /// whole, so nothing is lost.
    @Test func checkoutTooltip_keepsTheFullFolderAndNamesTheBranchOnce() {
        let row = Self.row(
            checkout: "fix-tax-rounding",
            fullCheckout: "duesmith-fix-tax-rounding",
            isBranch: false,
            fact: .init(uncommittedFiles: 2)
        )
        #expect(Self.lineTwo(row) == "fix-tax-rounding · 2 files uncommitted")
        #expect(SessionRowFactText.tooltip(for: row, now: .now, locale: Self.english)
            == "Login work · duesmith-fix-tax-rounding")
        #expect(SessionRowFactText.spokenLabel(for: row, projectName: "duesmith", now: .now, locale: Self.english)
            == "Shell, Login work, Worktree duesmith-fix-tax-rounding, duesmith, 2 files uncommitted")

        #expect(SessionRowFactText.tooltip(for: Self.row(checkout: "feat/login"), now: .now, locale: Self.english)
            == "Login work · feat/login")
    }

    @Test func voiceOver_readsTheLabel_theBranch_thenTheFactOrTheState() {
        let fact = Self.row(checkout: "feat/login", fact: .init(agents: Self.idleAgent.agents, uncommittedFiles: 3))
        #expect(SessionRowFactText.spokenLabel(for: fact, projectName: "weir", now: .now, locale: Self.english)
            == "Idle, Login work, Branch feat/login, weir, 3 files uncommitted, Claude")

        // The fact dropped is the state, which VoiceOver reads first.
        let idle = Self.row(checkout: "feat/login", fact: Self.idleAgent)
        #expect(SessionRowFactText.spokenLabel(for: idle, projectName: "weir", now: .now, locale: Self.english)
            == "Idle, Login work, Branch feat/login, weir, Claude")

        let japanese = Self.row(checkout: "feat/login", fact: Self.idleAgent, locale: Self.japanese)
        #expect(SessionRowFactText.spokenLabel(for: japanese, projectName: "weir", now: .now, locale: Self.japanese)
            == "待機中、Login work、ブランチ feat/login、weir、Claude")
    }

    // MARK: - Elsewhere the row is a choice

    private struct LabeledCheckouts {
        let session: WorkspaceSession
        let project: Project
        let login: ContainerID
        let tax: ContainerID
    }

    private static func labeledCheckouts() throws -> LabeledCheckouts {
        let root = WorkspaceSessionFixture.projectRootURL("parent").appendingPathComponent("duesmith")
        let (session, project) = WorkspaceSessionFixture.withProject(name: "Duesmith App", rootURL: root)
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        let parent = root.deletingLastPathComponent()
        let login = Worktree(
            label: "login-redesign",
            workingDirectory: parent.appendingPathComponent("duesmith-login-redesign"),
            gitRef: GitRef(branchName: "feat/login"),
            origin: .gitWorktree
        )
        let tax = Worktree(
            label: "Fix-Tax-Rounding",
            workingDirectory: parent.appendingPathComponent("duesmith-fix-tax-rounding"),
            gitRef: GitRef(branchName: nil, headSHA: "abc"),
            origin: .gitWorktree
        )
        session.projects[index].worktrees = [login, tax]
        let loginRow = ContainerID.worktree(projectID: project.id, worktreeID: login.id)
        let taxRow = ContainerID.worktree(projectID: project.id, worktreeID: tax.id)
        session.renameRow(loginRow, to: "Login work", runtimes: [])
        session.renameRow(taxRow, to: "Tax rounding", runtimes: [])
        return LabeledCheckouts(session: session, project: session.projects[index], login: loginRow, tax: taxRow)
    }

    @Test func theWorktreeMenu_givesALabeledCheckoutsBranch_orItsFolder() throws {
        let fixture = try Self.labeledCheckouts()
        let (session, project) = (fixture.session, fixture.project)
        let rows = Dictionary(uniqueKeysWithValues: Self.model(session, project).rows.map { ($0.id, $0) })
        let sections = SidebarPresentedSections.computed(
            project: project, session: session, window: session.primaryWindowID,
            queue: AttentionQueue(), pullRequest: { _ in nil }, gitFacts: { _ in nil }
        )
        let entries = WorktreeDropdownEntry.entries(of: project, in: sections, rows: rows)
        let parent = project.rootURL.deletingLastPathComponent()

        let branched = try #require(entries.first { $0.id == fixture.login })
        #expect(branched.name == "Login work")
        #expect(branched.branch == "feat/login")
        let loginPath = PathFormatting.abbreviateHome(parent.appendingPathComponent("duesmith-login-redesign").path)
        #expect(PathFormatting.abbreviateHome(branched.folder.path) == loginPath)
        #expect(WorktreeDropdownText.detail(
            name: branched.name, branch: branched.branch, folder: loginPath,
            shownFolder: rows[fixture.login]?.checkout.flatMap { $0.isBranch ? nil : $0.shown },
            agentCount: 2, locale: Self.english
        ) == "feat/login · \(loginPath) · Agents 2")

        let detached = try #require(entries.first { $0.id == fixture.tax })
        #expect(detached.name == "Tax rounding")
        #expect(detached.branch == "Fix-Tax-Rounding")
        #expect(detached.folder == parent.appendingPathComponent("duesmith-fix-tax-rounding"))
        #expect(WorktreeDropdownText.detail(
            name: detached.name, branch: detached.branch, folder: PathFormatting.abbreviateHome(detached.folder.path),
            shownFolder: rows[fixture.tax]?.checkout.flatMap { $0.isBranch ? nil : $0.shown },
            agentCount: 0, locale: Self.english
        ) == "fix-tax-rounding")
    }

    @Test func labeledAllProjectsCards_showTheBranchOrShortenedFolder() throws {
        let fixture = try Self.labeledCheckouts()
        let (session, project) = (fixture.session, fixture.project)
        session.openTab(container: fixture.login)
        session.openTab(container: fixture.tax)
        let registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = RecordingWindowPresenter()
        let cards = AllProjectsModel.cards(AllProjectsModel.Sources(
            session: session, window: session.primaryWindowID, registry: registry, queue: AttentionQueue(),
            runtimes: [], approvals: ApprovalLedger(), pullRequest: { _ in nil }, gitFacts: { _ in nil },
            locale: Self.english
        ))
        #expect(cards.allSatisfy { $0.projectID == project.id })

        let branched = try #require(cards.first { $0.id == fixture.login })
        #expect(branched.name == "Login work")
        #expect(branched.branch == "feat/login")
        #expect(branched.checkout == "feat/login")
        #expect(branched.folderName == "duesmith-login-redesign")
        #expect(AllProjectsText.place(project: branched.projectName, branch: branched.branch, checkout: branched.checkout)
            == "Duesmith App / feat/login")
        #expect(AllProjectsText.spokenPlace(
            project: branched.projectName,
            branch: branched.branch,
            checkout: branched.checkout,
            locale: Self.english
        )
            == "Duesmith App, feat/login")

        let detached = try #require(cards.first { $0.id == fixture.tax })
        #expect(detached.name == "Tax rounding")
        #expect(detached.branch == "Fix-Tax-Rounding")
        #expect(detached.checkout == "fix-tax-rounding")
        #expect(detached.folderName == "duesmith-fix-tax-rounding")
        #expect(AllProjectsText.place(project: detached.projectName, branch: detached.branch, checkout: detached.checkout)
            == "Duesmith App / fix-tax-rounding")
        #expect(AllProjectsText.spokenPlace(
            project: detached.projectName,
            branch: detached.branch,
            checkout: detached.checkout,
            locale: Self.english
        )
            == "Duesmith App, fix-tax-rounding")
    }
}
