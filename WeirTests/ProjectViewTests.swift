// ProjectViewTests.swift
// Weir — each project's view: saved for the projects no window shows, read back, and put back as a window takes the project.

import Foundation
import Observation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite(.tags(.persistence))
@MainActor
struct ProjectViewTests {
    /// A session whose primary shows `shown` on `shownTab`, and a project
    /// `left` that no window shows, with two sessions: `leftFirst`, which a
    /// window was on when it left, and `leftLast`, the project's last
    /// session.
    @MainActor
    private struct Fixture {
        let session: WorkspaceSession
        let shown: Project
        let shownTab: Tab
        let left: Project
        let leftFirst: Tab
        let leftLast: Tab

        init() {
            let (session, shown) = WorkspaceSessionFixture.withProject(name: "shown")
            shownTab = session.openTab(container: .project(shown.id))
            left = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("left"), suggestedName: "left")
            // Behind the primary, which stays on `shown`: `left` is a
            // project no window has shown, with no view.
            leftFirst = session.openTab(container: .project(left.id), in: session.primaryWindowID, intent: .person, selects: false)
            leftLast = session.openTab(container: .project(left.id), in: session.primaryWindowID, intent: .person, selects: false)
            session.setActiveTab(shownTab.id)
            session.primarySelection.projectID = shown.id
            self.session = session
            self.shown = shown
        }

        /// What a window showed of `left` when it left: its first session,
        /// laid out apart from the defaults.
        var leftView: ProjectView {
            ProjectView(
                projectID: left.id,
                activeContainerID: .project(left.id),
                activeTabID: leftFirst.id,
                sidebarWidth: 333,
                sidebarHidden: true,
                isChangesPanelPresented: true,
                changesPanelWidth: 444,
                changesPanelFilter: ConversationKey(provider: .claude, conversationID: "c1", isFallback: false)
            )
        }

        /// `leftView` as a save writes it: the panel's filter is the
        /// running app's, never written, so a launch opens the panel on
        /// "All".
        var leftViewAsWritten: ProjectView {
            var written = leftView
            written.changesPanelFilter = nil
            return written
        }

        func addProject(_ name: String) -> Project {
            session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL(name), suggestedName: name)
        }

        /// The session as the next launch reads it back from disk.
        func relaunched() throws -> WorkspaceSession {
            try Self.relaunch(session.makeSnapshot())
        }

        static func relaunch(_ snapshot: SessionSnapshot) throws -> WorkspaceSession {
            try relaunch(JSONEncoder().encode(snapshot))
        }

        static func relaunch(_ data: Data) throws -> WorkspaceSession {
            let restored = WorkspaceSession()
            try restored.restore(from: JSONDecoder().decode(SessionSnapshot.self, from: data))
            return restored
        }

    }

    /// A view of `project` on its own row, laid out at a width no window
    /// here has: one a save or a read must leave out.
    private static func staleView(
        of project: Project,
        sidebarHidden: Bool = false,
        isChangesPanelPresented: Bool = false
    ) -> ProjectView {
        ProjectView(
            projectID: project.id,
            activeContainerID: .project(project.id),
            activeTabID: nil,
            sidebarWidth: 999,
            sidebarHidden: sidebarHidden,
            isChangesPanelPresented: isChangesPanelPresented
        )
    }

    // MARK: - Saved and read back

    @Test func aSnapshotWithoutProjectViews_readsAsNoMemory() throws {
        let fixture = Fixture()
        fixture.session.projectViews[fixture.left.id] = fixture.leftView
        var json = try JSONObjectFixture.object(encoding: fixture.session.makeSnapshot())
        // A v6 file a build before the views wrote.
        json.removeValue(forKey: "projectViews")
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        let restored = try Fixture.relaunch(data)

        #expect(decoded.projectViews.isEmpty)
        #expect(restored.projectViews.isEmpty)
        #expect(restored.project(fixture.left.id) != nil)
    }

    @Test func aViewOfAGoneProject_isDroppedOnLoad() throws {
        let fixture = Fixture()
        var snapshot = fixture.session.makeSnapshot()
        let gone = ProjectView(
            projectID: UUID(),
            activeContainerID: .loose,
            activeTabID: nil,
            sidebarWidth: 300,
            sidebarHidden: false,
            isChangesPanelPresented: false
        )
        snapshot.projectViews = [gone, fixture.leftView]

        let restored = try Fixture.relaunch(snapshot)

        #expect(restored.projectViews == [fixture.left.id: fixture.leftViewAsWritten])
    }

    @Test func aViewThatDoesNotDecode_dropsOnlyItself() throws {
        let fixture = Fixture()
        let third = fixture.addProject("third")
        fixture.session.projectViews[fixture.left.id] = fixture.leftView
        fixture.session.projectViews[third.id] = Self.staleView(of: third)
        var json = try JSONObjectFixture.object(encoding: fixture.session.makeSnapshot())
        let views = try #require(json["projectViews"] as? [[String: Any]])
        try #require(views.count == 2)
        json["projectViews"] = [
            views[0], ["projectID": third.id.uuidString, "sidebarWidth": "wide"], ["sidebarWidth": 300], views[1]
        ]

        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        let restored = try Fixture.relaunch(data)
        let good = [fixture.leftViewAsWritten, Self.staleView(of: third)]

        #expect(decoded.projectViews == good)
        #expect(restored.projectViews == Dictionary(uniqueKeysWithValues: good.map { ($0.projectID, $0) }))
    }

    @Test func aProjectShownInAWindow_isSavedByWhatTheWindowShows() throws {
        let fixture = Fixture()
        let hidden = fixture.addProject("hidden")
        let visible = fixture.session.primarySelection
        visible.sidebarWidth = 301
        let selection = fixture.session.addWindow(showing: hidden.id, layoutFrom: visible.windowID)
        let hiddenTab = fixture.session.openTab(container: .project(hidden.id), in: selection.windowID)
        selection.sidebarWidth = 363
        selection.sidebarHidden = true
        selection.isChangesPanelPresented = true
        selection.changesPanelWidth = 475
        fixture.session.setWindow(selection.windowID, isHidden: true)
        fixture.session.projectViews[fixture.shown.id] = Self.staleView(of: fixture.shown)
        fixture.session.projectViews[hidden.id] = Self.staleView(of: hidden)
        fixture.session.projectViews[fixture.left.id] = fixture.leftView

        let snapshot = fixture.session.makeSnapshot()
        let window = try #require(snapshot.windows.first)
        #expect(snapshot.windows.map(\.projectID) == [fixture.shown.id])
        #expect(window.activeContainerID == .project(fixture.shown.id))
        #expect(window.activeTabID == fixture.shownTab.id)
        #expect(window.sidebarWidth == 301)
        #expect(!window.isHidden)
        #expect(snapshot.projectViews == [fixture.leftView, ProjectView(
            projectID: hidden.id, activeContainerID: .project(hidden.id), activeTabID: hiddenTab.id,
            sidebarWidth: 363, sidebarHidden: true, isChangesPanelPresented: true, changesPanelWidth: 475
        )])
    }

    /// The window whose record holds a project's place.
    enum RecordHolder: CaseIterable, Sendable {
        case primary
        case laterWindow
    }

    /// A view of a project a window's record holds is stale: the record
    /// lays the window out, and the view is dropped on read and not saved.
    @Test(arguments: RecordHolder.allCases)
    func aViewOfAProjectAWindowRecordHolds_isDroppedOnRead_andNotSaved(_ holder: RecordHolder) throws {
        let fixture = Fixture()
        fixture.session.primarySelection.sidebarWidth = 300
        let held: Project
        switch holder {
        case .primary:
            held = fixture.shown
        case .laterWindow:
            held = fixture.addProject("other")
            fixture.session.addWindow(showing: held.id, layoutFrom: fixture.session.primaryWindowID)
        }
        var snapshot = fixture.session.makeSnapshot()
        snapshot.projectViews = [
            fixture.leftView,
            Self.staleView(of: held, sidebarHidden: true, isChangesPanelPresented: true)
        ]

        let restored = try Fixture.relaunch(snapshot)

        #expect(restored.projectViews == [fixture.left.id: fixture.leftViewAsWritten])
        #expect(restored.makeSnapshot().projectViews == [fixture.leftViewAsWritten])
        let window = try #require(restored.windowIDs.first { restored.selection($0)?.projectID == held.id })
        let selection = try #require(restored.selection(window))
        #expect(selection.sidebarWidth == 300)
        #expect(!selection.sidebarHidden)
        #expect(!selection.isChangesPanelPresented)
    }

    @Test func aViewOnAGroup_landsOnTheScratchTabs() throws {
        let fixture = Fixture()
        let groupTab = fixture.session.openTab(container: .loose)
        fixture.session.setActiveContainer(.project(fixture.shown.id))
        var snapshot = fixture.session.makeSnapshot()
        var view = fixture.leftView
        view.activeTabID = groupTab.id
        snapshot.projectViews = [view]
        // A window left `left` on a group's tab, written by a build that
        // could still make one after groups became scratch tabs.
        let group: [String: Any] = ["group": ["_0": UUID().uuidString]]
        var json = try JSONObjectFixture.object(encoding: snapshot)
        var tabs = try #require(json["tabs"] as? [String: Any])
        var tab = try #require(tabs[groupTab.id.uuidString] as? [String: Any])
        tab["container"] = group
        tabs[groupTab.id.uuidString] = tab
        json["tabs"] = tabs
        var views = try #require(json["projectViews"] as? [[String: Any]])
        views[0]["activeContainerID"] = group
        json["projectViews"] = views

        let restored = try Fixture.relaunch(JSONSerialization.data(withJSONObject: json))
        // Read as the scratch tabs, and saved so; the tab alone would land
        // the window on the scratch tabs even without that.
        #expect(restored.projectViews[fixture.left.id]?.activeContainerID == .loose)
        #expect(restored.makeSnapshot().projectViews.map(\.activeContainerID) == [.loose])
        let window = restored.addWindow(showing: fixture.left.id, layoutFrom: restored.primaryWindowID).windowID

        #expect(restored.selection(window)?.activeContainerID == .loose)
        #expect(restored.selection(window)?.activeTabID == groupTab.id)
        #expect(restored.selection(window)?.projectID == fixture.left.id)
        // Putting a view back is not the person choosing the scratch tabs.
        #expect(restored.scratchOwnerWindowID == nil)
    }

    @Test func aViewWhoseTabIsGone_fallsBackToTheProjectsLastSession() throws {
        let fixture = Fixture()
        fixture.session.projectViews[fixture.left.id] = fixture.leftView
        let restored = try fixture.relaunched()
        let stale = UUID()
        restored.projectViews[fixture.left.id]?.activeTabID = stale
        #expect(restored.tab(stale) == nil)
        #expect(restored.projectViews[fixture.left.id]?.activeTabID == stale)
        #expect(restored.tabs(in: .project(fixture.left.id)).map(\.id) == [fixture.leftFirst.id, fixture.leftLast.id])
        restored.primarySelection.sidebarWidth = 280

        let window = restored.addWindow(showing: fixture.left.id, layoutFrom: restored.primaryWindowID).windowID

        #expect(restored.selection(window)?.activeTabID == fixture.leftLast.id)
        #expect(restored.selection(window)?.activeContainerID == .project(fixture.left.id))
        // The new window's chrome is the one it was opened from, not the view's.
        #expect(restored.selection(window)?.sidebarWidth == 280)
        #expect(restored.projectViews.isEmpty)
    }

    // MARK: - Put back and forgotten

    @Test func removingAProject_forgetsOnlyItsView() {
        let fixture = Fixture()
        let kept = fixture.addProject("kept")
        let keptView = Self.staleView(of: kept)
        fixture.session.projectViews[fixture.left.id] = fixture.leftView
        fixture.session.projectViews[kept.id] = keptView

        fixture.session.removeProject(fixture.left.id)

        #expect(fixture.session.project(fixture.left.id) == nil)
        #expect(fixture.session.projectViews == [kept.id: keptView])
        #expect(fixture.session.makeSnapshot().projectViews == [keptView])
    }

    @Test func aWindowSwitchingToAProject_startsFromItsRememberedView_andForgetsIt() throws {
        let fixture = Fixture()
        let window = fixture.session.primaryWindowID
        let frame = CGRect(x: 10, y: 20, width: 900, height: 700)
        fixture.session.primarySelection.frame = frame
        fixture.session.primarySelection.sidebarWidth = 280
        let outgoingFilter = ConversationKey(provider: .codex, conversationID: "shown", isFallback: true)
        fixture.session.primarySelection.changesPanelFilter = outgoingFilter
        fixture.session.projectViews[fixture.left.id] = fixture.leftView

        fixture.session.showProject(fixture.left.id, in: window, intent: .person, reason: .person)
        let selection = try #require(fixture.session.selection(window))

        #expect(selection.projectID == fixture.left.id)
        // The tab the window was on, not the project's last session.
        #expect(selection.activeTabID == fixture.leftFirst.id)
        #expect(selection.activeContainerID == .project(fixture.left.id))
        #expect(selection.changesPanelFilter == fixture.leftView.changesPanelFilter)
        // The window's own layout stays the window's: its frame, and its
        // chrome, whatever the view of an earlier build says.
        #expect(selection.frame == frame)
        #expect(selection.sidebarWidth == 280)
        #expect(!selection.sidebarHidden)
        #expect(!selection.isChangesPanelPresented)
        #expect(selection.changesPanelWidth == nil)
        // The view is the window's now; the project it left keeps one.
        #expect(fixture.session.projectViews == [fixture.shown.id: ProjectView(
            projectID: fixture.shown.id, activeContainerID: .project(fixture.shown.id), activeTabID: fixture.shownTab.id,
            sidebarWidth: 280, sidebarHidden: false, isChangesPanelPresented: false, changesPanelFilter: outgoingFilter
        )])
        #expect(fixture.session.projectsWithWindowRecords.isDisjoint(with: fixture.session.projectViews.keys))
    }

    @Test func aWindowWithNoProjectTakingAProject_appliesAndForgetsItsView() throws {
        let fixture = Fixture()
        fixture.session.setActiveContainer(.loose)
        fixture.session.primarySelection.projectID = nil
        fixture.session.projectViews[fixture.left.id] = fixture.leftView

        let window = fixture.session.primaryWindowID
        fixture.session.showProject(fixture.left.id, in: window, intent: .person, reason: .person)
        let selection = try #require(fixture.session.selection(window))

        #expect(fixture.session.windowIDs == [window])
        #expect(selection.projectID == fixture.left.id)
        #expect(selection.activeTabID == fixture.leftFirst.id)
        #expect(selection.changesPanelFilter?.conversationID == "c1")
        #expect(selection.sidebarWidth == SessionLayoutDefaults.sidebarWidth)
        #expect(!selection.isChangesPanelPresented)
        #expect(fixture.session.projectViews.isEmpty)
    }

    @Test func aWindowWhoseProjectIsRemoved_takesTheViewOfTheProjectItSwitchesTo() throws {
        let fixture = Fixture()
        ProjectSwitchRecorder.connect(to: fixture.session)
        let gone = fixture.addProject("gone")
        let selectionBefore = fixture.session.addWindow(showing: gone.id, layoutFrom: fixture.session.primaryWindowID)
        let window = selectionBefore.windowID
        selectionBefore.sidebarWidth = 275
        selectionBefore.changesPanelWidth = 355
        fixture.session.projectViews[fixture.left.id] = fixture.leftView

        // The window's project goes: it switches at once to the project
        // opened most recently that no other window shows.
        fixture.session.removeProject(gone.id)
        let selection = try #require(fixture.session.selection(window))

        #expect(fixture.session.project(gone.id) == nil)
        #expect(selection === selectionBefore)
        #expect(selection.projectID == fixture.left.id)
        #expect(selection.activeContainerID == .project(fixture.left.id))
        #expect(selection.activeTabID == fixture.leftFirst.id)
        #expect(selection.changesPanelFilter == fixture.leftView.changesPanelFilter)
        #expect(selection.sidebarWidth == 275)
        #expect(!selection.sidebarHidden)
        #expect(!selection.isChangesPanelPresented)
        #expect(selection.changesPanelWidth == 355)
        #expect(fixture.session.primarySelection.activeTabID == fixture.shownTab.id)
        #expect(fixture.session.projectViews.isEmpty)
    }

    @Test func aLaunchSavedWithThePrimaryOnScratch_keepsEveryView() throws {
        let fixture = Fixture()
        let scratch = fixture.session.openTab(container: .loose)
        fixture.session.primarySelection.projectID = nil
        let shownView = ProjectView(
            projectID: fixture.shown.id,
            activeContainerID: .project(fixture.shown.id),
            activeTabID: fixture.shownTab.id,
            sidebarWidth: 333,
            sidebarHidden: true,
            isChangesPanelPresented: true
        )
        fixture.session.projectViews[fixture.shown.id] = shownView
        // Saved with a primary that names no project, as the single window
        // of an earlier build could leave it.
        let saved = fixture.session.makeSnapshot()
        #expect(saved.windows.first?.projectID == nil)
        #expect(saved.projectViews.map(\.projectID) == [fixture.shown.id])

        let restored = try Fixture.relaunch(saved)
        // The first project no window holds and no view remembers: the
        // window stays on its scratch tab, laid out as it was, and the
        // view of the project a window left is kept for it.
        #expect(restored.primarySelection.projectID == fixture.left.id)
        #expect(restored.primarySelection.activeTabID == scratch.id)
        #expect(restored.primarySelection.sidebarWidth != 333)
        #expect(restored.projectViews == [fixture.shown.id: shownView])

        // Every project remembered: the primary names none of them.
        var everyView = saved
        everyView.projectViews.append(fixture.leftView)
        let alone = try Fixture.relaunch(everyView)
        #expect(alone.primarySelection.projectID == nil)
        #expect(alone.primarySelection.activeTabID == scratch.id)
        #expect(alone.projectViews == [fixture.shown.id: shownView, fixture.left.id: fixture.leftViewAsWritten])
    }

    @Test func aWindowOnScratchKeepingItsProject_takesNoOtherProjectsView() throws {
        let fixture = Fixture()
        ProjectSwitchRecorder.connect(to: fixture.session)
        let scratch = fixture.session.openTab(container: .loose)
        fixture.session.setActiveTab(scratch.id)
        let window = WorkspaceSessionFixture.addWindow(to: fixture.session)
        let other = try #require(fixture.session.selection(window))
        other.projectID = fixture.left.id
        fixture.session.setActiveTab(fixture.leftFirst.id, in: window)
        other.sidebarWidth = 333
        // The other window closes, so `left` keeps what it showed; then a
        // project no window shows goes away.
        fixture.session.removeWindow(window)
        let kept = try #require(fixture.session.projectViews[fixture.left.id])
        #expect(kept.activeContainerID == .project(fixture.left.id))
        #expect(kept.activeTabID == fixture.leftFirst.id)
        #expect(kept.sidebarWidth == 333)
        let gone = fixture.addProject("gone")
        fixture.session.removeProject(gone.id)

        // The primary stays on its scratch tab, in its project: nothing
        // takes it to `left`, whose view waits for the next window to show
        // the project.
        #expect(fixture.session.primarySelection.projectID == fixture.shown.id)
        #expect(fixture.session.primarySelection.activeTabID == scratch.id)
        #expect(fixture.session.primarySelection.activeContainerID == .loose)
        #expect(fixture.session.projectViews[fixture.left.id] == kept)
    }

    @Test func aViewNamingNoContainer_opensItsProjectsLastSession() throws {
        let fixture = Fixture()
        fixture.session.closeTab(fixture.leftFirst.id)
        fixture.session.closeTab(fixture.leftLast.id)
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: fixture.left.id, in: fixture.session)
        let row = ContainerID.worktree(projectID: fixture.left.id, worktreeID: worktree.id)
        let checkout = fixture.session.openTab(container: row, in: fixture.session.primaryWindowID, intent: .person, selects: false)
        var json = try JSONObjectFixture.object(encoding: fixture.session.makeSnapshot())
        json["projectViews"] = [["projectID": fixture.left.id.uuidString]]

        let restored = try Fixture.relaunch(JSONSerialization.data(withJSONObject: json))
        #expect(restored.projectViews == [fixture.left.id: ProjectView(
            projectID: fixture.left.id, activeContainerID: .loose, activeTabID: nil
        )])
        #expect(restored.tabs(in: .project(fixture.left.id)).isEmpty)
        let window = restored.addWindow(showing: fixture.left.id, layoutFrom: restored.primaryWindowID).windowID

        #expect(restored.selection(window)?.activeTabID == checkout.id)
        #expect(restored.selection(window)?.activeContainerID == row)
        #expect(restored.projectViews.isEmpty)
    }

    /// The window is laid out from its record, through every switch: a
    /// view the build before wrote brings back its tab, never its chrome.
    @Test func aViewAnEarlierBuildWrote_withItsChrome_readsAndLeavesTheWindowsChrome() throws {
        let fixture = Fixture()
        fixture.session.primarySelection.sidebarWidth = 280
        fixture.session.primarySelection.isChangesPanelPresented = true
        fixture.session.primarySelection.changesPanelWidth = 360
        var json = try JSONObjectFixture.object(encoding: fixture.session.makeSnapshot())
        // As the build before wrote a view: the chrome it laid windows out by.
        json["projectViews"] = [[
            "projectID": fixture.left.id.uuidString,
            "activeTabID": fixture.leftFirst.id.uuidString,
            "activeContainerID": ["project": ["_0": fixture.left.id.uuidString]],
            "sidebarWidth": 399,
            "sidebarHidden": true,
            "isChangesPanelPresented": false,
            "changesPanelWidth": 555,
            "changesPanelAgent": "codex"
        ]]
        let restored = try Fixture.relaunch(JSONSerialization.data(withJSONObject: json))
        #expect(restored.projectViews == [fixture.left.id: ProjectView(
            projectID: fixture.left.id, activeContainerID: .project(fixture.left.id), activeTabID: fixture.leftFirst.id,
            sidebarWidth: 399, sidebarHidden: true, isChangesPanelPresented: false, changesPanelWidth: 555
        )])
        let selection = restored.primarySelection
        #expect(selection.sidebarWidth == 280)
        #expect(selection.isChangesPanelPresented)
        #expect(selection.changesPanelWidth == 360)

        restored.showProject(fixture.left.id, in: restored.primaryWindowID, intent: .person, reason: .person)

        #expect(selection.activeTabID == fixture.leftFirst.id)
        #expect(selection.activeContainerID == .project(fixture.left.id))
        #expect(selection.changesPanelFilter == nil)
        #expect(selection.sidebarWidth == 280)
        #expect(!selection.sidebarHidden)
        #expect(selection.isChangesPanelPresented)
        #expect(selection.changesPanelWidth == 360)
    }

    @Test func aSavedView_stillWritesTheWindowsChrome_forTheBuildBefore() throws {
        let fixture = Fixture()
        let selection = fixture.session.primarySelection
        selection.sidebarWidth = 280
        selection.sidebarHidden = true
        selection.isChangesPanelPresented = true
        selection.changesPanelWidth = 360

        fixture.session.showProject(fixture.left.id, in: fixture.session.primaryWindowID, intent: .person, reason: .person)
        let json = try JSONObjectFixture.object(encoding: fixture.session.makeSnapshot())

        // The view of the project left, as the build before reads it.
        let views = try #require(json["projectViews"] as? [[String: Any]])
        let shown = try #require(views.first { $0["projectID"] as? String == fixture.shown.id.uuidString })
        #expect(shown["activeTabID"] as? String == fixture.shownTab.id.uuidString)
        #expect((shown["activeContainerID"] as? [String: [String: String]]) == ["project": ["_0": fixture.shown.id.uuidString]])
        #expect(shown["sidebarWidth"] as? Double == 280)
        #expect(shown["sidebarHidden"] as? Bool == true)
        #expect(shown["isChangesPanelPresented"] as? Bool == true)
        #expect(shown["changesPanelWidth"] as? Double == 360)
        // And the window's record holds the same chrome, which this build reads.
        let window = try #require((json["windows"] as? [[String: Any]])?.first)
        #expect(window["sidebarWidth"] as? Double == 280)
        #expect(window["isChangesPanelPresented"] as? Bool == true)
    }

    // MARK: - Saving

    @Test func aSave_keepsTheViewsBesideTheWindowsRecords() throws {
        let fixture = Fixture()
        let other = fixture.addProject("other")
        fixture.session.addWindow(showing: other.id, layoutFrom: fixture.session.primaryWindowID)
        fixture.session.projectViews[fixture.left.id] = fixture.leftView

        let snapshot = fixture.session.makeSnapshot()
        let json = try JSONObjectFixture.object(encoding: snapshot)
        let view = try #require((json["projectViews"] as? [[String: Any]])?.first)
        #expect(json["version"] as? Int == 6)
        #expect((json["projectViews"] as? [[String: Any]])?.count == 1)
        #expect(view["projectID"] as? String == fixture.left.id.uuidString)
        #expect(view["changesPanelAgent"] == nil)
        #expect(view["changesPanelFilter"] == nil)
        #expect(snapshot.windows.map(\.projectID) == [fixture.shown.id, other.id])
        let restored = try Fixture.relaunch(snapshot)
        let saved = restored.makeSnapshot()

        let written = fixture.leftViewAsWritten
        #expect(restored.projectViews == [fixture.left.id: written])
        #expect(saved.projectViews == [written])
        // The window made again keeps its project out of the views.
        #expect(saved.windows.map(\.projectID) == [fixture.shown.id, other.id])
        #expect(restored.carriedRootFields["projectViews"] == nil)
    }

    @Test func twoViewsOfOneProject_keepTheFirst() throws {
        let fixture = Fixture()
        var snapshot = fixture.session.makeSnapshot()
        var second = fixture.leftView
        second.sidebarWidth = 111
        second.activeTabID = fixture.leftLast.id
        snapshot.projectViews = [fixture.leftView, second]

        let restored = try Fixture.relaunch(snapshot)

        #expect(restored.projectViews == [fixture.left.id: fixture.leftViewAsWritten])
    }

    @Test func theViews_areSavedInTheProjectsOrder() {
        let fixture = Fixture()
        let third = fixture.addProject("third")
        fixture.session.projectViews[third.id] = ProjectView(
            projectID: third.id,
            activeContainerID: .project(third.id),
            activeTabID: nil,
            sidebarWidth: 300,
            sidebarHidden: false,
            isChangesPanelPresented: false
        )
        fixture.session.projectViews[fixture.left.id] = fixture.leftView

        let before = fixture.session.makeSnapshot().projectViews.map(\.projectID)
        fixture.session.projects.reverse()
        let after = fixture.session.makeSnapshot().projectViews.map(\.projectID)

        #expect(before == [fixture.left.id, third.id])
        #expect(after == [third.id, fixture.left.id])
    }

    @Test func savedStateObservation_reportsAProjectViewChange() {
        let fixture = Fixture()
        let notified = Recorded(false)
        withObservationTracking {
            fixture.session.readSavedState()
        } onChange: {
            notified.value = true
        }

        fixture.session.projectViews[fixture.left.id] = fixture.leftView

        #expect(notified.value)
    }
}
