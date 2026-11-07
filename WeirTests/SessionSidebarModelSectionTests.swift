// SessionSidebarModelSectionTests.swift
// Weir — sidebar section order, folded rows, and the controls that change a worktree's section.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

extension SessionSidebarModelTests {
    /// A project with a worktree for each section: one with a tab, one
    /// Weir made whose request is merged, two agents' worktrees nobody
    /// opened, and the folder.
    struct SectionedRows {
        let working: ContainerID
        let merged: ContainerID
        let agentA: ContainerID
        let agentB: ContainerID
        let folder: ContainerID
    }

    // swiftlint:disable:next large_tuple
    private static func sectionedProject() throws -> (session: WorkspaceSession, project: Project, ids: SectionedRows) {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let working = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        let merged = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .created)
        let agentA = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        let agentB = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        let row = { (worktree: Worktree) in ContainerID.worktree(projectID: project.id, worktreeID: worktree.id) }
        session.openTab(container: row(working), in: session.primaryWindowID, intent: .repair, selects: false)
        let ids = SectionedRows(
            working: row(working),
            merged: row(merged),
            agentA: row(agentA),
            agentB: row(agentB),
            folder: .project(project.id)
        )
        return try (session, #require(session.project(project.id)), ids)
    }

    private static func sectionedModel(
        _ session: WorkspaceSession,
        _ project: Project,
        merged: ContainerID,
        open: Set<SidebarSection>
    ) -> SessionSidebarModel {
        let pullRequest = { (row: ContainerID) in row == merged ? PRInfoFixture.make(number: 127, state: .merged) : nil }
        let sections = SidebarPresentedSections.computed(
            project: project,
            session: session,
            window: session.primaryWindowID,
            queue: AttentionQueue(),
            pullRequest: pullRequest,
            gitFacts: { _ in nil }
        )
        return SessionSidebarModel(
            project: project,
            session: session,
            window: session.primaryWindowID,
            queue: AttentionQueue(),
            runtimes: [],
            approvals: ApprovalLedger(),
            pullRequest: pullRequest,
            gitFacts: { _ in nil },
            locale: english,
            layout: .init(sections: sections, openSections: open)
        )
    }

    @Test func theFoldLines_countTheirRows_andBuildThemOnlyWhenOpened() throws {
        let (session, project, ids) = try Self.sectionedProject()
        let sections = SidebarPresentedSections(sections: [
            ids.folder: .working, ids.working: .working, ids.merged: .cleanable, ids.agentA: .other, ids.agentB: .other
        ])
        var built: [ContainerID] = []
        func model(open: Set<SidebarSection>) -> SessionSidebarModel {
            built = []
            return SessionSidebarModel(
                project: project, session: session, window: session.primaryWindowID,
                queue: AttentionQueue(), runtimes: [], approvals: ApprovalLedger(),
                pullRequest: { row in
                    built.append(row)
                    return row == ids.merged ? PRInfoFixture.make(number: 127, state: .merged) : nil
                },
                gitFacts: { _ in nil }, locale: Self.english,
                layout: .init(sections: sections, openSections: open)
            )
        }

        let folded = model(open: [])
        #expect(built == [ids.folder, ids.working])
        #expect(folded.rows.map(\.id) == [ids.folder, ids.working])
        #expect(folded.items.map(\.id) == [
            .row(ids.folder), .row(ids.working), .fold(project.id, .cleanable), .fold(project.id, .other)
        ])
        let folds = folded.items.compactMap { item -> SessionSidebarModel.Fold? in
            guard case let .fold(fold) = item else { return nil }
            return fold
        }
        #expect(folds.map(\.count) == [1, 2])
        #expect(folds.allSatisfy { !$0.isOpen })

        let open = model(open: [.cleanable, .other])
        #expect(built == [ids.folder, ids.working, ids.merged, ids.agentA, ids.agentB])
        #expect(open.items.map(\.id) == [
            .row(ids.folder), .row(ids.working), .fold(project.id, .cleanable), .row(ids.merged),
            .fold(project.id, .other), .row(ids.agentA), .row(ids.agentB)
        ])
        #expect(open.rows.map(\.section) == [.working, .working, .cleanable, .other, .other])
        let cleanable = try #require(open.rows.first { $0.id == ids.merged })
        #expect(cleanable.factText == "PR #127 · Merged")
    }

    /// A worktree whose folder is gone folds under its own line, before the
    /// rows ready to clean up, and comes out of it once a tab opens there.
    @Test func aMissingWorktree_foldsUnderItsOwnLine_untilATabOpensThere() throws {
        let (session, initial) = Self.project()
        let spikeID = try #require(initial.worktrees.first?.id)
        let goneID = try #require(initial.worktrees.last?.id)
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: initial.id, in: session, admission: .created)
        let project = try #require(session.project(initial.id))
        let merged = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
        let spike = ContainerID.worktree(projectID: project.id, worktreeID: spikeID)
        let gone = ContainerID.worktree(projectID: project.id, worktreeID: goneID)
        let folded = Self.sectionedModel(session, project, merged: merged, open: [])
        let expected: [SidebarItemID] = [
            .row(.project(project.id)), .row(spike), .fold(project.id, .missing), .fold(project.id, .cleanable)
        ]
        #expect(folded.items.map(\.id) == expected)

        let opened = Self.sectionedModel(session, project, merged: merged, open: [.missing])
        #expect(opened.items.map(\.id) == [
            .row(.project(project.id)), .row(spike), .fold(project.id, .missing), .row(gone), .fold(project.id, .cleanable)
        ])
        #expect(opened.rows.first { $0.id == gone }?.section == .missing)
        #expect(opened.rows.first { $0.id == gone }?.isMissing == true)

        _ = session.openTab(container: gone)
        session.setActiveContainer(.project(project.id))
        let withTab = Self.sectionedModel(session, project, merged: merged, open: [])
        #expect(withTab.rows.first { $0.id == gone }?.section == .working)
        #expect(withTab.rows.first { $0.id == gone }?.isMissing == true)
        #expect(!withTab.items.contains { $0.id == .fold(project.id, .missing) })
    }

    /// A list with no row has no line.
    @Test func aListWithNoRow_hasNoLine() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let model = Self.sectionedModel(session, project, merged: .loose, open: [])
        #expect(model.items.map(\.id) == [.row(.project(project.id))])
    }

    /// Without the window's layout (the worktree menu, all projects), every
    /// row is built, each in the section it is placed in now.
    @Test func withoutAWindowsLayout_everyRowIsBuilt() throws {
        let (session, project, ids) = try Self.sectionedProject()
        let rows = SessionSidebarModel(
            project: project, session: session, queue: AttentionQueue(), runtimes: [], approvals: ApprovalLedger(),
            pullRequest: { $0 == ids.merged ? PRInfoFixture.make(number: 127, state: .merged) : nil },
            gitFacts: { _ in nil }, locale: Self.english
        ).rows
        #expect(rows.map(\.id) == [ids.folder, ids.working, ids.merged, ids.agentA, ids.agentB])
        #expect(rows.map(\.section) == [.working, .working, .cleanable, .other, .other])
    }

    /// The selected row stays a working one, so choosing a row never hides
    /// it.
    @Test func theSelectedRow_isAWorkingRow() throws {
        let (session, project, ids) = try Self.sectionedProject()
        let agent = ids.agentA
        // Moved there, not chosen: a choice would admit the row.
        session.setActiveContainer(.project(project.id))
        session.setActiveContainer(agent, in: session.primaryWindowID, intent: .repair)
        let agentID = try #require(agent.worktreeID)
        #expect(session.worktree(projectID: project.id, worktreeID: agentID)?.admission == .discovered)
        let model = Self.sectionedModel(session, project, merged: ids.merged, open: [])
        #expect(model.rows.first { $0.id == agent }?.section == .working)
        #expect(model.rows.first { $0.id == agent }?.isActive == true)
    }

    /// An item on a row's pane keeps the row working, found through the
    /// pane's tab; one for a session that stopped before its pane opened,
    /// through the row's folder.
    @Test func anItemForARow_keepsItWorking() throws {
        let (session, project, ids) = try Self.sectionedProject()
        let agentA = ids.agentA
        let root = try #require(session.rootDirectory(of: agentA))
        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .sessionRow(worktreeRoot: root), episodeToken: "1")),
            kind: .stop(.processExited),
            subject: .sessionRow(projectID: project.id, worktreeRoot: root),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        let sections = SidebarPresentedSections.computed(
            project: project,
            session: session,
            window: session.primaryWindowID,
            queue: queue,
            pullRequest: { _ in nil },
            gitFacts: { _ in nil }
        )
        #expect(sections.section(of: agentA) == .working)
        #expect(sections.section(of: ids.agentB) == .other)
    }

    /// One of the other worktrees says it is not a working row and how it becomes one,
    /// and VoiceOver names its list, which on screen only the line above says.
    @Test func anOtherWorktree_saysOpeningItMakesItAWorkingRow() throws {
        let (session, project, ids) = try Self.sectionedProject()
        let model = Self.sectionedModel(session, project, merged: ids.merged, open: [.other])
        let row = try #require(model.rows.first { $0.id == ids.agentA })

        let tooltip = SessionRowFactText.tooltip(for: row, now: .now, locale: Self.english)
        #expect(tooltip.hasSuffix("\nNot among the worktrees above. Opening it adds it there."), "\(tooltip)")
        let spoken = SessionRowFactText.spokenLabel(for: row, projectName: "weir", now: .now, locale: Self.english)
        #expect(spoken.contains(", weir, Other Worktrees, "), "\(spoken)")
        let working = try #require(model.rows.first { $0.id == ids.working })
        #expect(!SessionRowFactText.tooltip(for: working, now: .now, locale: Self.english).contains("Not among the worktrees above"))
    }

    /// The menu offers to release admission on an inactive working worktree with no tabs.
    @Test func removeFromWorking_requiresAnAdmittedInactiveWorkingWorktreeWithNoTabs() throws {
        let (session, project, ids) = try Self.sectionedProject()
        let model = Self.sectionedModel(session, project, merged: ids.merged, open: [.other])
        let made = ids.merged
        // One of the other worktrees has nowhere further to go.
        let other = try #require(model.rows.first { $0.id == ids.agentA })
        let otherWorktree = try #require(project.worktrees
            .first { ContainerID.worktree(projectID: project.id, worktreeID: $0.id) == ids.agentA })
        #expect(!SessionSidebarModel.offersRemoveFromWorking(other, worktree: otherWorktree, hasTabs: false))

        // Without its merged request, the row Weir made is a working one.
        let working = Self.sectionedModel(session, project, merged: .loose, open: [])
        let madeRow = try #require(working.rows.first { $0.id == made })
        let madeWorktree = try #require(project.worktrees.first { ContainerID.worktree(projectID: project.id, worktreeID: $0.id) == made })
        #expect(SessionSidebarModel.offersRemoveFromWorking(madeRow, worktree: madeWorktree, hasTabs: false))
        #expect(!SessionSidebarModel.offersRemoveFromWorking(madeRow, worktree: madeWorktree, hasTabs: true))
        var discovered = madeWorktree
        discovered.admission = .discovered
        #expect(!SessionSidebarModel.offersRemoveFromWorking(madeRow, worktree: discovered, hasTabs: false))
        var pinned = madeWorktree
        pinned.origin = .userPinned
        #expect(!SessionSidebarModel.offersRemoveFromWorking(madeRow, worktree: pinned, hasTabs: false))
        var gone = madeWorktree
        gone.missingSince = Date(timeIntervalSince1970: 0)
        #expect(!SessionSidebarModel.offersRemoveFromWorking(madeRow, worktree: gone, hasTabs: false))

        session.setActiveContainer(made, in: session.primaryWindowID, intent: .person)
        let selected = try Self.sectionedModel(session, #require(session.project(project.id)), merged: .loose, open: [])
        let selectedRow = try #require(selected.rows.first { $0.id == made })
        #expect(!SessionSidebarModel.offersRemoveFromWorking(selectedRow, worktree: madeWorktree, hasTabs: false))
    }

    /// The folder's row is named as any row is, and its tooltip and VoiceOver
    /// say in words that it is the repository. Its line at rest
    /// states its Git facts, as any row's does.
    @Test func theFoldersRow_saysItIsTheRepository() throws {
        let (session, project) = Self.project()
        let folder = try #require(Self.model(session, project).rows.first { $0.isMainFolder })

        #expect(folder.factText == "Idle")
        #expect(SessionRowFactText.tooltip(for: folder, now: .now, locale: Self.english) == "main · Repository folder")
        let spoken = SessionRowFactText.spokenLabel(for: folder, projectName: "weir", now: .now, locale: Self.english)
        #expect(spoken == "Shell, main, weir, Repository folder, Idle", "\(spoken); a shell says Shell once")
        let clean = GitFactsFixture.make(branch: "main", commits: nil, unpushed: nil, uncommitted: 0, base: nil)
        let read = try #require(Self.model(session, project) { _ in clean }.rows.first { $0.isMainFolder })
        #expect(read.factText == "No changes")
        // A worktree's row at rest is idle.
        #expect(Self.model(session, project).rows.first { !$0.isMainFolder }?.factText == "Idle")
    }

    /// A detached worktree has no branch: its folder names it.
    @Test func aDetachedWorktree_isNamedByItsFolder() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "alpha")
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[index].worktrees = [Worktree(
            label: "(unnamed)",
            workingDirectory: URL(fileURLWithPath: "/tmp/alpha-detached"),
            gitRef: GitRef(branchName: nil, headSHA: "abc"),
            origin: .gitWorktree,
            admission: .opened
        )]
        let row = try #require(Self.model(session, session.projects[index]).rows.first { !$0.isMainFolder })
        #expect(row.name == "alpha-detached")
        #expect(row.nameTruncation == .name)
    }

    /// Opening one of the other worktrees makes it a working row for good:
    /// it stays one after the person moves to another row.
    @Test func anOtherWorktreeThePersonOpens_staysAWorkingRow() throws {
        let (session, project, ids) = try Self.sectionedProject()
        session.setActiveContainer(ids.agentA, in: session.primaryWindowID, intent: .person)
        session.setActiveContainer(ids.folder, in: session.primaryWindowID, intent: .person)

        let model = try Self.sectionedModel(session, #require(session.project(project.id)), merged: ids.merged, open: [])
        #expect(model.rows.first { $0.id == ids.agentA }?.section == .working)
        #expect(!model.rows.contains { $0.id == ids.agentB })
    }
}
