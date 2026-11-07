// WorkspaceSessionContainersTests.swift
// Weir — project and tab membership, container selection, and removal in the workspace model.

import Foundation
import Testing
@testable import Weir

@Suite("WorkspaceSession +Containers")
@MainActor
struct WorkspaceSessionContainersTests {
    private typealias Fixture = WorkspaceSessionFixture

    @Test(arguments: [nil, "Explicit"] as [String?])
    func addOrActivateProject_appendsWithItsExplicitOrFolderName(name: String?) throws {
        let (session, first) = Fixture.withProject(name: "Existing")
        let tab = session.openTab(container: .project(first.id))
        let window = session.primaryWindowID
        let before = try #require(session.currentNavTarget(in: window))
        let folder = Fixture.projectRootURL("containers").appendingPathComponent("new")
        let project = session.addOrActivateProject(rootURL: folder, suggestedName: name)

        #expect(session.projects.map(\.id) == [first.id, project.id])
        #expect(session.project(first.id)?.name == "Existing")
        #expect(project.rootURL == folder.standardizedFileURL)
        #expect(project.name == (name ?? "new"))
        #expect(project.paletteIndex == 1)
        #expect(session.project(first.id)?.paletteIndex == 0)
        #expect(session.tabs.map(\.id) == [tab.id])
        #expect(session.currentNavTarget(in: window) == before)
    }

    @Test("addOrActivateProject shows a newline in the folder's name, and keeps it in the name it saves")
    func addOrActivateProject_folderWithANewline_showsItAndSavesItAsItIs() throws {
        let session = WorkspaceSession()
        let project = session.addOrActivateProject(rootURL: Fixture.projectRootURL("containers").appendingPathComponent("feat\nline"))
        #expect(project.name == "feat\u{240A}line")
        #expect(try JSONObjectFixture.object(encoding: project)["name"] as? String == "feat\nline")
    }

    @Test func addOrActivateProject_reusesTheStandardizedPath_andSelectsItsTab() throws {
        let session = WorkspaceSession()
        let parent = Fixture.projectRootURL("containers")
        let folder = parent.appendingPathComponent("a")
        let first = session.addOrActivateProject(rootURL: folder, suggestedName: "A")
        let second = session.addOrActivateProject(rootURL: parent.appendingPathComponent("b"), suggestedName: "B")
        let tab = session.openTab(container: .project(first.id))
        let other = session.openTab(container: .project(second.id))
        let window = session.primaryWindowID
        try #require(session.currentNavTarget(in: window) == .init(container: .project(second.id), tabID: other.id))
        try #require(session.recentProjectPaths == [second.rootURL, first.rootURL])
        let alias = parent.appendingPathComponent("unused/../a")
        try #require(alias.path != folder.path && alias.standardizedFileURL == first.rootURL)

        let reopened = session.addOrActivateProject(rootURL: alias, suggestedName: "Ignored")

        #expect(reopened.id == first.id)
        #expect(reopened.name == "A")
        #expect(reopened.rootURL == first.rootURL)
        #expect(reopened.paletteIndex == first.paletteIndex)
        #expect(session.projects.map(\.id) == [first.id, second.id])
        #expect(session.tabs.map(\.id) == [tab.id, other.id])
        #expect(session.currentNavTarget(in: window) == .init(container: .project(first.id), tabID: tab.id))
        #expect(session.recentProjectPaths == [first.rootURL, second.rootURL])
    }

    private func worktree(in session: WorkspaceSession, project: Project) throws -> ContainerID {
        let worktree = try #require(session.attachGitWorktree(
            projectID: project.id,
            label: "branch",
            workingDirectory: Fixture.projectRootURL("branch"),
            branchName: "branch"
        ))
        return .worktree(projectID: project.id, worktreeID: worktree.id)
    }

    @Test func directAndLooseTabs_keepOnlyTheirContainerInSessionOrder() throws {
        let (session, project) = Fixture.withProject()
        let other = session.addOrActivateProject(rootURL: Fixture.projectRootURL("other"))
        let branch = try worktree(in: session, project: project)
        let first = session.openTab(container: .project(project.id))
        let scratch = session.openTab(container: .loose)
        let otherTab = session.openTab(container: .project(other.id))
        let branchTab = session.openTab(container: branch)
        let second = session.openTab(container: .project(project.id))
        let nextScratch = session.openTab(container: .loose)

        #expect(session.directTabs(in: project.id).map(\.id) == [first.id, second.id])
        #expect(session.directTabs(in: other.id).map(\.id) == [otherTab.id])
        #expect(session.looseTabs.map(\.id) == [scratch.id, nextScratch.id])
        #expect(session.tabs(in: branch).map(\.id) == [branchTab.id])
    }

    enum RowContents: CaseIterable, Sendable {
        case empty, staleRememberedTab, liveRememberedTab
    }

    @Test(arguments: RowContents.allCases)
    func setActiveContainer_selectsItsRememberedTab_orFallsBack(contents: RowContents) throws {
        let (session, project) = Fixture.withProject()
        let row = ContainerID.project(project.id)
        let window = session.primaryWindowID
        let expected: UUID?
        switch contents {
        case .empty:
            expected = nil
        case .staleRememberedTab, .liveRememberedTab:
            let first = session.openTab(container: row)
            let second = session.openTab(container: row)
            session.rememberLastActive(tabID: contents == .liveRememberedTab ? second.id : UUID(), container: row)
            expected = contents == .liveRememberedTab ? second.id : first.id
        }
        let unrelated = session.openTab(container: .loose)
        try #require(session.currentNavTarget(in: window) == .init(container: .loose, tabID: unrelated.id))

        session.setActiveContainer(row)

        #expect(session.currentNavTarget(in: window) == .init(container: row, tabID: expected))
        #expect(session.looseTabs.map(\.id) == [unrelated.id])
    }

    @Test(arguments: [false, true])
    func renameProject_changesOnlyTheMatchingName(hasTarget: Bool) {
        let (session, first) = Fixture.withProject(name: "Keep")
        let second = session.addOrActivateProject(rootURL: Fixture.projectRootURL("target"), suggestedName: "Old")
        session.renameProject(hasTarget ? second.id : UUID(), to: "New")

        var expected = second
        if hasTarget {
            expected.name = "New"
        }
        #expect(session.projects == [first, expected])
    }

    @Test("setProjectPaletteIndex writes the value through")
    func setProjectPaletteIndex_writesValue() {
        let (session, project) = WorkspaceSessionFixture.withProject()
        session.setProjectPaletteIndex(project.id, to: 3)
        #expect(session.projects.first?.paletteIndex == 3)
        session.setProjectPaletteIndex(project.id, to: nil)
        #expect(session.projects.first?.paletteIndex == nil)
    }

    @Test func removeProject_dropsItsRootAndWorktreePanes_andKeepsTheSelectedProject() throws {
        let (session, project) = Fixture.withProject()
        let keep = session.addOrActivateProject(rootURL: Fixture.projectRootURL("keep"))
        let tab = session.openTab(container: .project(project.id))
        PaneActions.split(session, direction: .horizontal)
        let rootPanes = try #require(session.tab(tab.id)).splitTree.allLeafIDs()
        try #require(rootPanes.count == 2)
        let branch = try worktree(in: session, project: project)
        let branchTab = session.openTab(container: branch)
        let scratch = session.openTab(container: .loose)
        let keptTab = session.openTab(container: .project(keep.id))
        let window = session.primaryWindowID
        let keptSelection = WorkspaceSession.NavTarget(container: .project(keep.id), tabID: keptTab.id)
        try #require(session.currentNavTarget(in: window) == keptSelection)
        try #require(session.projectViews[project.id] != nil)

        let freed = session.removeProject(project.id)

        #expect(session.projects.map(\.id) == [keep.id])
        #expect(session.tabs.map(\.id) == [scratch.id, keptTab.id])
        #expect(Set(freed) == Set(rootPanes + branchTab.splitTree.allLeafIDs()))
        #expect(freed.count == 3)
        #expect(session.projectViews[project.id] == nil)
        #expect(session.currentNavTarget(in: window) == keptSelection)
    }

    @Test func removeProject_unknownID_returnsEmpty() throws {
        let (session, project) = Fixture.withProject()
        _ = session.openTab(container: .project(project.id))
        _ = session.openTab(container: .loose)
        let window = session.primaryWindowID
        let before = try #require(session.currentNavTarget(in: window))
        let projects = session.projects
        let tabs = session.tabs
        let views = session.projectViews

        #expect(session.removeProject(UUID()).isEmpty)
        #expect(session.projects == projects)
        #expect(session.tabs == tabs)
        #expect(session.projectViews == views)
        #expect(session.currentNavTarget(in: window) == before)
    }
}
