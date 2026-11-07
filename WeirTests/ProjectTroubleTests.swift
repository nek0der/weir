// ProjectTroubleTests.swift
// Weir — a project whose folder is gone or whose Git cannot run: what the sidebar, the ▾, and the menus offer.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct ProjectTroubleTests {
    /// A session whose project's folder was deleted after it was added, as
    /// the last sync found (`GitSyncCoordinator`).
    private static func projectWithDeletedRoot() throws -> (session: WorkspaceSession, project: Project) {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "gone")
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[index].trouble = .folderMissing
        return (session, session.projects[index])
    }

    // MARK: - Classification

    @Test func aListingInAFolderThatIsGone_isAMissingFolder_whateverGitSaid() {
        let error = GitProcessError.launchFailed("posix_spawn failed")
        #expect(ProjectTrouble.of(error, folderExists: false) == .folderMissing)
        let refused = GitProcessError.nonZeroExit(.failure("fatal: not a git repository"))
        #expect(ProjectTrouble.of(refused, folderExists: false) == .folderMissing)
    }

    @Test func noGitToStart_orTheStubWithoutTheCommandLineTools_isGitUnavailable() {
        #expect(ProjectTrouble.of(GitProcessError.launchFailed("no such file"), folderExists: true, hasGit: false) == .gitUnavailable)
        let stub = GitProcessError.nonZeroExit(.failure(
            "xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools), missing xcrun"
        ))
        #expect(ProjectTrouble.of(stub, folderExists: true) == .gitUnavailable)
    }

    /// A folder that is there but cannot be entered fails the launch with
    /// git in place: not a reason to send the person to install git.
    @Test func aLaunchThatFailedWithGitInPlace_isAListingThatFailed() {
        let message = "posix_spawn failed: Permission denied"
        let error = GitProcessError.launchFailed(message)
        #expect(ProjectTrouble.of(error, folderExists: true, hasGit: true) == .listingFailed(detail: message))
    }

    @Test func aRefusal_keepsTheFirstLineOfWhatGitSaid() {
        let refused = GitProcessError.nonZeroExit(.failure("fatal: detected dubious ownership in repository\nhint: run"))
        #expect(ProjectTrouble.of(refused, folderExists: true) == .listingFailed(detail: "fatal: detected dubious ownership in repository"))
        #expect(ProjectTrouble.of(GitProcessError.timedOut(seconds: 30), folderExists: true) == .listingFailed(detail: nil))
    }

    // MARK: - What is offered

    @Test func aDeletedRoot_marksTheFolderMissing_andLeavesItsWorktreesAlone() throws {
        let (session, project) = try Self.projectWithDeletedRoot()
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        let worktree = WorktreeFixture.make(workingDirectory: URL(fileURLWithPath: "/tmp/gone-feat"), admission: .opened)
        let missing = WorktreeFixture.make(isMissing: true, admission: .opened)
        session.projects[index].worktrees.append(contentsOf: [worktree, missing])

        #expect(session.isFolderMissing(.project(project.id)))
        // A worktree's folder is somewhere else, and its own sync says
        // whether it is gone.
        #expect(!session.isFolderMissing(.worktree(projectID: project.id, worktreeID: worktree.id)))
        #expect(session.isFolderMissing(.worktree(projectID: project.id, worktreeID: missing.id)))
        #expect(!session.isFolderMissing(.loose))
    }

    @Test func aDeletedRoot_offersNoNewWorktree_andAnotherTroubleStillDoes() throws {
        let (_, project) = try Self.projectWithDeletedRoot()
        #expect(!project.canMakeWorktree)
        var unavailable = project
        unavailable.trouble = .gitUnavailable
        #expect(!unavailable.canMakeWorktree)
        var refused = project
        refused.trouble = .listingFailed(detail: "fatal: bad config")
        #expect(refused.canMakeWorktree)
        #expect(!refused.isRootMissing)
        refused.trouble = nil
        #expect(refused.canMakeWorktree)
    }

    @Test func aDeletedRoot_dimsTheFolderRow_soItsFinderAndChangesAreOff() throws {
        let (session, project) = try Self.projectWithDeletedRoot()
        let model = SessionSidebarModel(
            project: project,
            session: session,
            queue: AttentionQueue(),
            runtimes: [],
            approvals: ApprovalLedger(),
            pullRequest: { _ in nil },
            gitFacts: { _ in nil },
            locale: Locale(identifier: "en")
        )
        let folder = try #require(model.rows.first { $0.isMainFolder })
        #expect(folder.isMissing)
    }

    /// A moved tab's panes start in the row's folder, so a project whose
    /// own folder is gone takes none, as a missing worktree takes none.
    @Test func aDeletedRoot_takesNoTabMovedOntoItsRow() throws {
        let (session, project) = try Self.projectWithDeletedRoot()
        let tab = session.openTab(container: .loose)
        #expect(!TabActions.wouldMove(.tab(tab.id), to: .project(project.id), in: session))
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[index].trouble = nil
        #expect(TabActions.wouldMove(.tab(tab.id), to: .project(project.id), in: session))
    }

    @Test func aDeletedRoot_cannotBeChosenInTheWorktreeDropdown() throws {
        let (session, project) = try Self.projectWithDeletedRoot()
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .opened)
        let current = try #require(session.project(project.id))
        let main = ContainerID.project(project.id)
        let other = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
        let sections = SidebarPresentedSections(sections: [main: .working, other: .working])

        let entries = WorktreeDropdownEntry.entries(of: current, in: sections, rows: [:])

        #expect(entries.map(\.container) == [main, other])
        #expect(entries.map(\.isMissing) == [true, false])
        #expect(WorktreeDropdownEntry.choosable(entries) == [other])
    }

    @Test func theHeader_carriesTheTrouble_withTheFolderItsSentenceNames() throws {
        let (session, project) = try Self.projectWithDeletedRoot()
        let window = session.primaryWindowID
        let sections = SidebarPresentedSections.computed(
            projectsOf: session,
            window: window,
            windowShowing: { _ in nil },
            queue: AttentionQueue(),
            pullRequest: { _ in nil },
            gitFacts: { _ in nil }
        )
        let model = SidebarListModel(
            session: session,
            window: window,
            sections: sections,
            windowShowing: { _ in nil },
            sources: SidebarListModel.Sources(
                queue: AttentionQueue(),
                runtimes: [],
                approvals: ApprovalLedger(),
                pullRequest: { _ in nil },
                gitFacts: { _ in nil },
                running: { _ in 0 },
                locale: Locale(identifier: "en")
            )
        )

        let header = try #require(model.headers.first { $0.id == project.id })

        #expect(header.trouble == SidebarProjectHeader.Trouble(kind: .folderMissing, folder: project.rootURL))
    }

    @Test func theTroubleIsNeverWrittenToTheSessionFile() throws {
        let (_, project) = try Self.projectWithDeletedRoot()
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded.trouble == nil)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["trouble"] == nil)
    }
}
