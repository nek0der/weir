// SidebarListModelTests.swift
// Weir — every project under its own header in the sidebar: the order, the folds, the counts, and the marks of a folded header.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct SidebarListModelTests {
    typealias Fixture = ProjectWindowsFixture

    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    /// The sidebar of `window`, read from `queue`, with `running` agents in
    /// each project.
    private static func model(
        _ fixture: Fixture,
        window: ProjectWindowState? = nil,
        queue: AttentionQueue = AttentionQueue(),
        running: [UUID: Int] = [:],
        openedByDrag: Set<UUID> = []
    ) -> SidebarListModel {
        let window = window ?? fixture.primary
        let others = fixture.session.otherWindowsByProject(than: window.id)
        let showing = { (id: UUID) in others[id] }
        let sections = SidebarPresentedSections.computed(
            projectsOf: fixture.session,
            window: window.id,
            windowShowing: showing,
            queue: queue,
            pullRequest: { _ in nil },
            gitFacts: { _ in nil }
        )
        return SidebarListModel(
            session: fixture.session,
            window: window.id,
            sections: sections,
            windowShowing: showing,
            sources: SidebarListModel.Sources(
                queue: queue,
                runtimes: [],
                approvals: ApprovalLedger(),
                pullRequest: { _ in nil },
                gitFacts: { _ in nil },
                running: { running[$0] ?? 0 },
                locale: english
            ),
            openedByDrag: openedByDrag
        )
    }

    /// The scratch tabs' row, as the left rail's button builds it.
    private static func scratchRow(_ fixture: Fixture, queue: AttentionQueue = AttentionQueue()) -> SessionSidebarModel.Row {
        SessionSidebarModel.scratchRow(
            window: fixture.primary.id,
            sources: SessionSidebarModel.Sources(
                session: fixture.session,
                index: SidebarRowIndex(session: fixture.session, queue: queue),
                runtimes: [],
                approvals: ApprovalLedger(),
                locale: english
            ),
            usageLimits: UsageLimits(queue: queue)
        )
    }

    /// The Scratch button's model, as the left rail's button builds it.
    private static func scratchModel(_ fixture: Fixture, now: Date = Date(timeIntervalSince1970: 0)) -> RailScratchModel {
        RailScratchModel(
            window: fixture.primary.id,
            session: fixture.session,
            queue: AttentionQueue(),
            runtimes: [],
            approvals: ApprovalLedger(),
            isCardUp: { _ in false },
            isHighlighted: false,
            shortcut: nil,
            now: now,
            locale: english
        )
    }

    /// An item of `kind` in a pane of `project`, as the attention list holds
    /// one.
    private static func item(
        _ id: AttentionItemID,
        _ kind: AttentionItemKind,
        in project: Project,
        runtimeID: String = UUID().uuidString,
        _ queue: inout AttentionQueue
    ) {
        queue.insert(
            id: id,
            kind: kind,
            subject: .runtime(id: runtimeID, provider: .claude, paneID: UUID(), tabID: nil, projectID: project.id),
            arrivedAt: Date()
        )
    }

    // MARK: - Empty

    /// With no project the list has no header, and says so with the way to
    /// add one, rather than leave a blank over the scratch row; with a
    /// project it lists it and says nothing.
    @Test func noProject_saysThereIsNone_andAProjectListsIt() {
        let fixture = Fixture()

        for project in [fixture.a, fixture.b, fixture.c] {
            fixture.session.removeProject(project.id)
        }
        let empty = Self.model(fixture)
        #expect(empty.emptyState == .noProjects)
        #expect(empty.headers.isEmpty && empty.items.isEmpty)

        let project = fixture.session.addOrActivateProject(
            rootURL: WorkspaceSessionFixture.projectRootURL("restored"),
            suggestedName: "restored"
        )
        let populated = Self.model(fixture)
        #expect(populated.emptyState == nil)
        #expect(populated.headers.map(\.id) == [project.id])
        #expect(populated.headers.map(\.name) == ["restored"])
    }

    // MARK: - Order and folds

    /// Every project has a header, in the window's order, new ones at the
    /// bottom; the window's project is open, a project with one working row
    /// folded by default.
    @Test func everyProject_isListedUnderItsHeader_inTheWindowsOrder() {
        let fixture = Fixture()
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(projectOrder: [fixture.c.id])

        let model = Self.model(fixture)

        #expect(model.headers.map(\.id) == [fixture.c.id, fixture.a.id, fixture.b.id])
        #expect(model.headers.map(\.isCurrent) == [false, true, false])
        #expect(model.headers.map(\.isCollapsed) == [false, false, true], "c is met and open; b has one row")
        #expect(model.items.map(\.id) == [
            .header(fixture.c.id), .row(.project(fixture.c.id)),
            .header(fixture.a.id), .row(.project(fixture.a.id)),
            .header(fixture.b.id)
        ])
        #expect(model.rows(ofProject: fixture.b.id).isEmpty, "a folded header builds no row")
        #expect(Set(model.items.map(\.id)).count == model.items.count, "no two lines share an id")
    }

    /// A header the person folded stays folded, the window's own included,
    /// and its rows are counted rather than built.
    @Test func aFoldedHeader_countsItsRows_andBuildsNone() throws {
        let fixture = Fixture()
        _ = try WorkspaceSessionFixture.appendWorktree(to: fixture.a.id, in: fixture.session, admission: .created)
        _ = try WorkspaceSessionFixture.appendWorktree(to: fixture.a.id, in: fixture.session, admission: .discovered)
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(
            projectOrder: [fixture.a.id, fixture.b.id, fixture.c.id],
            collapsedProjects: [fixture.a.id]
        )

        let model = Self.model(fixture)
        let group = try #require(model.groups.first)
        let header = group.header

        #expect(header.id == fixture.a.id)
        #expect(header.isCollapsed)
        #expect(header.workingCount == 2)
        #expect(header.moreCount == 1)
        #expect(group.rows == nil)
        #expect(model.items.map(\.id) == [
            .header(fixture.a.id), .header(fixture.b.id), .row(.project(fixture.b.id)),
            .header(fixture.c.id), .row(.project(fixture.c.id))
        ])
    }

    /// A folded project a dragged tab rested on is drawn open for the drag
    /// alone: its rows are built, and the window's arrangement still has it
    /// folded, so a drag that goes elsewhere leaves it as it was.
    @Test func aFoldedProjectOpenedByDrag_isDrawnOpen_andStaysFoldedInTheArrangement() {
        let fixture = Fixture()
        let arrangement = SidebarArrangement(
            projectOrder: [fixture.a.id, fixture.b.id, fixture.c.id],
            collapsedProjects: [fixture.b.id]
        )
        fixture.primary.selection.sidebarArrangement = arrangement

        let model = Self.model(fixture, openedByDrag: [fixture.b.id])

        #expect(model.headers.first { $0.id == fixture.b.id }?.isCollapsed == false)
        #expect(model.rows(ofProject: fixture.b.id).map(\.id) == [.project(fixture.b.id)])
        #expect(fixture.primary.selection.sidebarArrangement == arrangement)
        #expect(Self.model(fixture).headers.first { $0.id == fixture.b.id }?.isCollapsed == true)
    }

    @Test func theDefaultFold_opensTheWindowsProject_andOneWithRows_butNotAnotherWindows() {
        #expect(SidebarFoldDefault.isOpen(isCurrent: true, isInOtherWindow: false, workingCount: 0))
        #expect(SidebarFoldDefault.isOpen(isCurrent: false, isInOtherWindow: false, workingCount: 2))
        #expect(!SidebarFoldDefault.isOpen(isCurrent: false, isInOtherWindow: false, workingCount: 0))
        #expect(!SidebarFoldDefault.isOpen(isCurrent: false, isInOtherWindow: false, workingCount: 1))
        #expect(!SidebarFoldDefault.isOpen(isCurrent: false, isInOtherWindow: true, workingCount: 5))
    }

    /// The button is drawn again only for what it shows, so a read with
    /// nothing changed has to compare equal.
    @Test func theScratchModel_isEqualUntilWhatItShowsChanges() {
        let fixture = Fixture()
        let before = Self.scratchModel(fixture)
        #expect(Self.scratchModel(fixture) == before)
        #expect(!before.isOnScratch)
        #expect(before.answerKey == nil)
        fixture.session.renameRow(.project(fixture.a.id), to: "Project-only name", runtimes: [])
        #expect(Self.scratchModel(fixture) == before)
        fixture.session.setActiveContainer(.loose, in: fixture.primary.id, intent: .person)
        let after = Self.scratchModel(fixture)
        #expect(after != before)
        #expect(after.isOnScratch)
    }

    /// The scratch row is the window's while it is on it, and never part of
    /// a project's list.
    @Test func theScratchRow_isActiveOnlyWhileTheWindowIsOnIt() {
        let fixture = Fixture()
        #expect(!Self.scratchRow(fixture).isActive)
        fixture.session.setActiveContainer(.loose, in: fixture.primary.id, intent: .person)
        #expect(Self.scratchRow(fixture).isActive)
        #expect(!Self.model(fixture).items.contains { $0.id == .row(.loose) })

        fixture.primary.selection.isChoosingProject = true
        #expect(!Self.scratchRow(fixture).isActive)
        #expect(!Self.model(fixture).items.contains { $0.id == .row(.loose) })
    }

    /// The command shows the scratch tabs at once, with nothing left over them.
    @Test(arguments: [false, true])
    func showScratch_closesTheLayers_andGoesToTheScratchTabs(reviewIsShown: Bool) throws {
        let fixture = Fixture()
        let scratch = fixture.scratchTab()
        if reviewIsShown {
            fixture.choose(scratch, in: fixture.primary)
            try Fixture.windowWritingAComment(fixture.primary, isOfNoProject: true)
            try #require(fixture.primary.review?.isShown == true)
        }
        let opening = fixture.primary.review?.opening
        let reviewSession = fixture.primary.reviewSession
        let composer = reviewSession?.composer
        fixture.primary.isAllProjectsPresented = true
        SupervisionWindowActions.showScratch(
            in: fixture.primary, session: fixture.session, registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter(windowID: fixture.primary.id, registry: fixture.registry)
        )
        #expect(!fixture.primary.isAllProjectsPresented)
        #expect(Self.scratchRow(fixture).isActive)
        #expect(fixture.primary.selection.activeTabID == scratch.id)
        #expect(fixture.session.scratchOwnerWindowID == fixture.primary.id)
        #expect(fixture.primary.review?.opening == opening)
        #expect(fixture.primary.reviewSession === reviewSession)
        #expect(fixture.primary.reviewSession?.composer == composer)
        #expect(fixture.primary.review?.isShown != true)
    }

    /// With only shells in it, the row wears a shell's mark and no badge, as
    /// a worktree's row of shells does, and is not called a project's folder.
    @Test func theScratchRow_ofShells_wearsTheShellMarkAlone() {
        let fixture = Fixture()
        _ = fixture.session.openTab(container: .loose, in: fixture.primary.id, intent: .person, selects: false)
        let row = Self.scratchRow(fixture)
        #expect(row.hasTabs)
        #expect(row.fact.glyph == .shell)
        #expect(row.agentKinds.isEmpty)
        #expect(!row.isMainFolder)
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(SessionRowFactText.scratchHint(startFolder: home, locale: Self.english) == "Its tabs start in the home folder")
    }

    /// A scratch tab's agent shows on the row while another row is open, so
    /// the wait is not found only by opening the scratch tabs.
    @Test func theScratchRow_showsItsAgentsWait() throws {
        let fixture = Fixture()
        let tab = fixture.session.openTab(container: .loose, in: fixture.primary.id, intent: .person, selects: false)
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let run = UUID().uuidString
        var queue = AttentionQueue()
        let waiting = AttentionItemID.prompt(EpisodeKey(origin: .runtime(run), episodeToken: "1"))
        let approval = ApprovalFact.test()
        Self.item(.approval(approval.key), .approval(approval), in: fixture.a, &queue)
        queue.insert(
            id: waiting,
            kind: .prompt(PromptWait(detail: nil)),
            subject: .runtime(id: run, provider: .claude, paneID: pane, tabID: tab.id, projectID: nil),
            arrivedAt: Date()
        )
        let row = Self.scratchRow(fixture, queue: queue)
        #expect(row.fact.glyph == .needsResponse)
        #expect(row.leadItemID == waiting)
        #expect(row.leadPaneID == pane)
        #expect(row.agentKinds == [.claude])
        #expect(!row.isActive)
        let folder = URL(fileURLWithPath: "/tmp/weir-scratch")
        #expect(SessionRowFactText.scratchHint(startFolder: folder, locale: Self.japanese) == "タブはweir-scratchで開始します")
    }

    // MARK: - Another window's project

    /// A project another window shows says so in its header and is folded
    /// by default.
    @Test func aProjectAnotherWindowShows_isMarked_andFoldedByDefault() throws {
        let fixture = Fixture()
        _ = try WorkspaceSessionFixture.appendWorktree(to: fixture.b.id, in: fixture.session, admission: .created)
        let before = try #require(Self.model(fixture).headers.first { $0.id == fixture.b.id })
        #expect(before.workingCount == 2)
        #expect(!before.isCollapsed)
        let other = try fixture.window(showing: fixture.b)
        fixture.registry.hide(other.id)

        let model = Self.model(fixture)
        let header = try #require(model.headers.first { $0.id == fixture.b.id })
        #expect(header.isInOtherWindow)
        #expect(header.isCollapsed)
        #expect(model.headers.filter(\.isInOtherWindow).map(\.id) == [fixture.b.id])
        // The other window lists the primary's project as another window's.
        let fromOther = Self.model(fixture, window: other)
        #expect(fromOther.headers.filter(\.isInOtherWindow).map(\.id) == [fixture.a.id])
        #expect(fromOther.headers.first { $0.id == fixture.b.id }?.isCurrent == true)
    }

    // MARK: - A folded header's marks

    /// A folded header holds one mark of each kind inside it, a wait first,
    /// then a stop, then a turn running; an unread turn none.
    @Test func aFoldedHeader_holdsAWaitAStopAndARun_inThatOrder_butNoUnread() {
        let fixture = Fixture()
        var queue = AttentionQueue()
        let turn = TurnID("t")
        let first = ApprovalFact.test()
        let second = ApprovalFact.test()
        let elsewhere = ApprovalFact.test()
        Self.item(.unread(turn), .unread(UnreadTurn(turnID: turn, changes: .unknown)), in: fixture.b, &queue)
        let stopped = AttentionItemID.stop(EpisodeKey(origin: .runtime("stopped"), episodeToken: "1"))
        Self.item(stopped, .stop(.processExited), in: fixture.b, runtimeID: "stopped", &queue)
        Self.item(.approval(first.key), .approval(first), in: fixture.b, &queue)
        Self.item(.approval(elsewhere.key), .approval(elsewhere), in: fixture.a, &queue)
        Self.item(.approval(second.key), .approval(second), in: fixture.b, &queue)

        let model = Self.model(fixture, queue: queue, running: [fixture.b.id: 2, fixture.a.id: 1])
        let folded = model.headers.first { $0.id == fixture.b.id }
        let open = model.headers.first { $0.id == fixture.a.id }

        #expect(folded?.marks == [.needsApproval, .stopped, .running])
        #expect(folded?.requestKeys == [first.key, second.key], "its cards stand beside the header")
        #expect(open?.marks == [], "an open header's rows show their own")
        #expect(open?.displayedMark == nil)
        #expect(open?.requestKeys == [])
    }

    /// It draws only the wait, so every header's mark is one wide, and its
    /// tooltip still names all three.
    @Test func aFoldedHeader_withAWaitAStopAndARun_drawsOnlyTheWait() throws {
        let fixture = Fixture()
        var queue = AttentionQueue()
        let approval = ApprovalFact.test()
        Self.item(.approval(approval.key), .approval(approval), in: fixture.b, &queue)
        let stopped = AttentionItemID.stop(EpisodeKey(origin: .runtime("stopped"), episodeToken: "1"))
        Self.item(stopped, .stop(.processExited), in: fixture.b, runtimeID: "stopped", &queue)

        let model = Self.model(fixture, queue: queue, running: [fixture.b.id: 1])
        let header = try #require(model.headers.first { $0.id == fixture.b.id })

        #expect(header.isCollapsed)
        #expect(header.displayedMark == .needsApproval)
        #expect(header.marks == [.needsApproval, .stopped, .running])
        let names = header.marks.map { StateGlyph.Kind($0).name.resolved(in: Self.english) }
        #expect(SidebarHeaderText.contents(names, locale: Self.english) == "Contains: Needs approval, Stopped, and Running")
    }

    @Test(arguments: [
        (AttentionCounts(questions: 1), 0, [SessionRowFact.Glyph.needsAnswer]),
        (AttentionCounts(prompts: 1), 0, [.needsResponse]),
        (AttentionCounts(signIns: 1), 0, [.needsSignIn]),
        (AttentionCounts(approvals: 1, questions: 1), 0, [.needsApproval]),
        (AttentionCounts(stops: 1), 1, [.stopped, .running]),
        (AttentionCounts(unread: 3), 0, []),
        (AttentionCounts(), 1, [.running]),
        (AttentionCounts(), 0, [])
    ])
    func theMarks_ofWhatIsInside(_ counts: AttentionCounts, running: Int, expected: [SessionRowFact.Glyph]) {
        #expect(SidebarProjectHeader.marks(counts: counts, running: running) == expected)
    }

    // MARK: - The hold, across projects

    /// While the pointer is on the sidebar, a row of a project the window
    /// does not show keeps its section too: every project's rows are in
    /// sight.
    @Test func theHold_keepsTheSectionsOfEveryProjectsRows() throws {
        let fixture = Fixture()
        let window = fixture.primary
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: fixture.b.id, in: fixture.session, admission: .discovered)
        let row = ContainerID.worktree(projectID: fixture.b.id, worktreeID: worktree.id)
        window.present(SidebarPresentedSections(sections: [row: .working]))
        window.isPointerInSidebar = true

        let computed = SidebarPresentedSections.computed(
            projectsOf: fixture.session,
            window: window.id,
            windowShowing: { _ in nil },
            queue: AttentionQueue(),
            pullRequest: { _ in nil },
            gitFacts: { _ in nil }
        )
        #expect(computed.section(of: row) == .other)
        #expect(window.presentedSections(computed: computed, isDragging: false).section(of: row) == .working)

        window.isPointerInSidebar = false
        #expect(window.presentedSections(computed: computed, isDragging: false).section(of: row) == .other)
    }

    /// ⌃⌘1…9 count the window's project's rows as the sidebar draws them:
    /// placing that project alone
    /// (`SidebarPresentedSections.computed(project:…)`) gives what placing
    /// every project (`AppState.sidebarSections(in:)`) gives for it.
    @Test func theWindowsProjectPlacedAlone_isWhatTheSidebarDraws() throws {
        let fixture = Fixture()
        let discovered = try WorkspaceSessionFixture.appendWorktree(to: fixture.a.id, in: fixture.session, admission: .discovered)
        let created = try WorkspaceSessionFixture.appendWorktree(to: fixture.a.id, in: fixture.session, admission: .created)
        let project = try #require(fixture.session.project(fixture.a.id))
        let alone = SidebarPresentedSections.computed(
            project: project,
            session: fixture.session,
            window: fixture.primary.id,
            queue: AttentionQueue(),
            pullRequest: { _ in nil },
            gitFacts: { _ in nil }
        )
        let every = SidebarPresentedSections.computed(
            projectsOf: fixture.session,
            window: fixture.primary.id,
            windowShowing: { _ in nil },
            queue: AttentionQueue(),
            pullRequest: { _ in nil },
            gitFacts: { _ in nil }
        )
        let folder = ContainerID.project(project.id)
        let createdRow = ContainerID.worktree(projectID: project.id, worktreeID: created.id)
        let discoveredRow = ContainerID.worktree(projectID: project.id, worktreeID: discovered.id)
        for sections in [alone, every] {
            #expect(sections.ordered(project).map(\.row) == [folder, createdRow, discoveredRow])
            #expect(sections.ordered(project).map(\.section) == [.working, .working, .other])
            #expect(SessionRowNavigation.workingRows(in: fixture.primary, session: fixture.session, sections: sections)
                == [folder, createdRow])
        }
    }

    /// With the sidebar hidden, every project placed as it stands
    /// (`AppState.sidebarSections(in:)`) is what the menus count and the
    /// palette reads: a row that came into the working rows since the
    /// sidebar last drew (opened from the palette) is counted, and another
    /// project's other worktrees stay other.
    @Test func withTheSidebarHidden_theRowsAsTheyStand_areCounted() throws {
        let fixture = Fixture()
        let window = fixture.primary
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: fixture.a.id, in: fixture.session, admission: .discovered)
        let row = ContainerID.worktree(projectID: fixture.a.id, worktreeID: worktree.id)
        let elsewhere = try WorkspaceSessionFixture.appendWorktree(to: fixture.b.id, in: fixture.session, admission: .discovered)
        let elsewhereRow = ContainerID.worktree(projectID: fixture.b.id, worktreeID: elsewhere.id)
        let place = {
            let others = fixture.session.otherWindowsByProject(than: window.id)
            return window.presentedSections(
                session: fixture.session,
                others: others,
                queue: AttentionQueue(),
                pullRequest: { _ in nil },
                gitFacts: { _ in nil },
                isDragging: false
            )
        }
        window.isSidebarPresented = false
        window.present(place())
        #expect(!window.presentedWorkingRows.contains(row))

        fixture.session.setActiveContainer(row, in: window.id, intent: .person)
        window.present(place())

        #expect(window.presentedWorkingRows.contains(row))
        #expect(SessionRowNavigation.workingRows(in: window, session: fixture.session, sections: window.presentedSections)
            == [.project(fixture.a.id), row])
        #expect(window.presentedSections.section(of: elsewhereRow) == .other)
        #expect(SupervisionPaletteFacts(window: window, session: fixture.session).rowSections[elsewhereRow] == .other)
    }

    /// The other windows by the project each shows: the window's own
    /// project is not listed.
    @Test func theOtherWindows_areListedByTheirProjects() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)

        fixture.registry.hide(other.id)
        let pending = WindowSelection()
        pending.projectID = fixture.c.id
        fixture.session.addSelection(pending)
        #expect(fixture.registry.window(pending.windowID) == nil)

        #expect(fixture.session.otherWindowsByProject(than: fixture.primary.id) == [fixture.b.id: other.id, fixture.c.id: pending.windowID])
        #expect(fixture.session.otherWindowsByProject(than: other.id) == [fixture.a.id: fixture.primary.id, fixture.c.id: pending.windowID])
    }

    // MARK: - Words

    private static func header(
        collapsed: Bool = false,
        working: Int = 3,
        more: Int = 55,
        isInOtherWindow: Bool = false
    ) -> SidebarProjectHeader {
        SidebarProjectHeader(
            id: UUID(),
            name: "weir",
            paletteIndex: nil,
            isCurrent: false,
            isCollapsed: collapsed,
            isInOtherWindow: isInOtherWindow,
            workingCount: working,
            moreCount: more,
            marks: [],
            requestKeys: []
        )
    }

    /// Only a folded header counts, and it counts every row it hides; an
    /// open one leaves the count to its rows and its sections' headings.
    @Test func theCount_showsOnlyWhileFolded_andSumsEveryHiddenRow() {
        #expect(SidebarHeaderText.count(Self.header(), locale: Self.english) == nil)
        #expect(SidebarHeaderText.count(Self.header(more: 0), locale: Self.english) == nil)
        #expect(SidebarHeaderText.count(Self.header(collapsed: true), locale: Self.english) == "58")
        #expect(SidebarHeaderText.count(Self.header(collapsed: true), locale: Self.japanese) == "58")
        #expect(SidebarHeaderText.count(Self.header(collapsed: true, more: 0), locale: Self.english) == "3")
    }

    @Test func voiceOver_readsTheProjectAndItsRows_orThatAnotherWindowShowsIt() {
        #expect(SidebarHeaderText.accessibilityLabel(Self.header(more: 0), locale: Self.english) == "weir, project, 3 worktrees")
        #expect(SidebarHeaderText
            .accessibilityLabel(Self.header(working: 1, more: 0), locale: Self.english) == "weir, project, 1 worktree")
        #expect(SidebarHeaderText.accessibilityLabel(Self.header(), locale: Self.english) == "weir, project, 3 worktrees, 55 more")
        #expect(SidebarHeaderText
            .accessibilityLabel(Self.header(collapsed: true), locale: Self.english) == "weir, project, 3 worktrees, 55 more")
        #expect(SidebarHeaderText
            .accessibilityLabel(Self.header(working: 1), locale: Self.english) == "weir, project, 1 worktree, 55 more")
        #expect(SidebarHeaderText.accessibilityLabel(Self.header(), locale: Self.japanese) == "weir、プロジェクト、ワークツリー 3、ほか 55")
        #expect(
            SidebarHeaderText.accessibilityLabel(Self.header(isInOtherWindow: true), locale: Self.english)
                == "weir, project, shown in another window"
        )
        #expect(
            SidebarHeaderText.accessibilityLabel(Self.header(isInOtherWindow: true), locale: Self.japanese)
                == "weir、プロジェクト、別のウインドウで表示中"
        )
    }

    @Test(arguments: [false, true], [false, true])
    func trouble_replacesTheCountAndOtherWindowIcon(collapsed: Bool, isInOtherWindow: Bool) {
        var header = Self.header(collapsed: collapsed, isInOtherWindow: isInOtherWindow)
        #expect(header.trailingMark == (isInOtherWindow ? .otherWindow : .count))
        for kind in [ProjectTrouble.folderMissing, .gitUnavailable, .listingFailed(detail: nil), .listingFailed(detail: "fatal")] {
            let trouble = SidebarProjectHeader.Trouble(kind: kind, folder: URL(fileURLWithPath: "/tmp/gone"))
            header.trouble = trouble
            #expect(header.trailingMark == .trouble(trouble))
        }
        header.trouble = nil
        #expect(header.trailingMark == (isInOtherWindow ? .otherWindow : .count))
    }

    @Test func troubleKinds_shareTheErrorSymbol() {
        #expect(ProjectTroubleText.symbol(.folderMissing) == "xmark.octagon.fill")
        #expect(ProjectTroubleText.symbol(.gitUnavailable) == "xmark.octagon.fill")
        #expect(ProjectTroubleText.symbol(.listingFailed(detail: nil)) == "xmark.octagon.fill")
        #expect(ProjectTroubleText.symbol(.listingFailed(detail: "fatal")) == "xmark.octagon.fill")
    }

    @Test(arguments: [false, true])
    func voiceOver_namesTrouble_evenWhenAnotherWindowShowsTheProject(isInOtherWindow: Bool) {
        var header = Self.header(isInOtherWindow: isInOtherWindow)
        header.trouble = SidebarProjectHeader.Trouble(kind: .folderMissing, folder: URL(fileURLWithPath: "/tmp/gone"))
        let english = SidebarHeaderText.accessibilityLabel(header, locale: Self.english)
        let japanese = SidebarHeaderText.accessibilityLabel(header, locale: Self.japanese)
        #expect(english.contains("Folder Missing"))
        #expect(japanese.contains(ProjectTroubleText.label(.folderMissing).resolved(in: Self.japanese)))
        #expect(english.contains("weir"))
        #expect(japanese.contains("weir"))
        if isInOtherWindow {
            #expect(english.contains("shown in another window"))
            #expect(japanese.contains("別のウインドウで表示中"))
        }
    }

    @Test func theContents_listTheMarksInWords() {
        #expect(SidebarHeaderText.contents([], locale: Self.english) == nil)
        #expect(SidebarHeaderText.contents(["Needs approval", "Running"], locale: Self.english) == "Contains: Needs approval and Running")
        #expect(SidebarHeaderText.contents(["承認待ち"], locale: Self.japanese) == "内訳：承認待ち")
        #expect(SidebarHeaderText.contents(["承認待ち", "実行中"], locale: Self.japanese) == "内訳：承認待ち、実行中")
    }

    @Test func thePlusAndTheOtherWindowMark_nameTheProject() {
        #expect(SidebarHeaderText.newWorktree(in: "alpha").resolved(in: Self.english) == "New Worktree in alpha…")
        #expect(SidebarHeaderText.newWorktree(in: "alpha").resolved(in: Self.japanese) == "alpha に新規ワークツリー…")
        #expect(SidebarHeaderText.otherWindowHelp("beta").resolved(in: Self.english) == "Brings forward the window that shows beta")
        #expect(SidebarHeaderText.otherWindowHelp("beta").resolved(in: Self.japanese) == "beta を表示しているウインドウを手前に移動します")
    }
}
