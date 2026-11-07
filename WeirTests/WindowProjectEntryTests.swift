// WindowProjectEntryTests.swift
// Weir — every way to another project switches the window it is used in, or brings forward the window that shows the project.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// Every entry point to another project goes through one
/// decision: project ▾, the palette's rows, a folder opened, a card,
/// ⌘J and the Needs Attention list, a notification, the menu bar's "Open
/// in Weir". Each switches the window it is used in, the one the person
/// was last in when used from outside a window, or brings forward the
/// window that already shows the project. None makes a window, except for
/// a folder after the first, when several come from outside at once and no
/// window shows it yet.
/// The menu bar's answer and resume move no window at all.
extension WindowProjectSwitchTests {

    // MARK: - Project ▾

    @Test func choosingAnotherProjectFromTheMenu_switchesThisWindow_andOpensNone() {
        let fixture = Fixture()
        let primary = fixture.primary
        fixture.choose(fixture.aOther, in: primary)
        fixture.session.primarySelection.sidebarWidth = 300
        fixture.session.primarySelection.isChangesPanelPresented = true

        // A → B: B is new to the window, which keeps its chrome.
        let shown = fixture.registry.show(project: fixture.b.id, in: fixture.session, from: primary, intent: .person)

        #expect(shown === primary)
        #expect(primary.selection.shownProjectID == fixture.b.id)
        #expect(primary.selection.activeTabID == fixture.bTab.id)
        #expect(primary.selection.sidebarWidth == 300)
        #expect(primary.selection.isChangesPanelPresented)
        #expect(fixture.registry.windows.count == 1)
        #expect(fixture.presenter.shown.isEmpty)
        #expect(fixture.session.projectViews[fixture.a.id]?.activeTabID == fixture.aOther.id)
        fixture.session.primarySelection.sidebarWidth = 260

        // B → A: A comes back on the tab it was left on, in the window's
        // chrome as it is now.
        fixture.registry.show(project: fixture.a.id, in: fixture.session, from: primary, intent: .person)

        #expect(primary.selection.activeTabID == fixture.aOther.id)
        #expect(fixture.session.projectViews[fixture.a.id] == nil)
        #expect(primary.selection.sidebarWidth == 260)
        #expect(primary.selection.isChangesPanelPresented)
        #expect(fixture.registry.windows.count == 1)
        // And B as it was left in turn, with the chrome written for the
        // build before.
        #expect(fixture.session.projectViews[fixture.b.id]?.activeTabID == fixture.bTab.id)
        #expect(fixture.session.projectViews[fixture.b.id]?.sidebarWidth == 260)
        fixture.expectInvariants()
    }

    @Test func aProjectSwitchedTo_comesFirstAmongTheRecentOnes() throws {
        let fixture = Fixture()
        let initial = [fixture.c.rootURL, fixture.b.rootURL, fixture.a.rootURL]
        #expect(fixture.session.recentProjectPaths == initial)

        fixture.registry.show(project: fixture.a.id, in: fixture.session, from: fixture.primary, intent: .person)
        #expect(fixture.session.recentProjectPaths == initial)

        fixture.registry.show(project: fixture.b.id, in: fixture.session, from: fixture.primary, intent: .person)
        #expect(fixture.session.recentProjectPaths == [fixture.b.rootURL, fixture.c.rootURL, fixture.a.rootURL])

        // A window that shows a project, brought forward, counts as using it.
        let other = try fixture.window(showing: fixture.c)
        fixture.registry.show(project: fixture.c.id, in: fixture.session, from: fixture.primary, intent: .person)
        #expect(fixture.presenter.shown == [other.id])
        #expect(fixture.session.recentProjectPaths == [fixture.c.rootURL, fixture.b.rootURL, fixture.a.rootURL])
    }

    @Test func removingTheShownProject_takesTheProjectUsedLast_notTheOneOpenedLast() {
        let fixture = Fixture()
        fixture.registry.show(project: fixture.b.id, in: fixture.session, from: fixture.primary, intent: .person)
        fixture.registry.show(project: fixture.a.id, in: fixture.session, from: fixture.primary, intent: .person)

        let recent = fixture.session.recentProjectPaths

        fixture.session.removeProject(fixture.a.id)

        // `c` was opened last; `b` was used since.
        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        #expect(fixture.primary.selection.activeTabID == fixture.bTab.id)
        #expect(fixture.presenter.shown.isEmpty)
        // Moving on from a removed project is not the person using the
        // project moved to, and the removed one's folder stays to reopen.
        #expect(fixture.session.recentProjectPaths == recent)
    }

    @Test func switchingBetweenOpenProjects_neverPushesARemovedProjectsFolderOut() {
        let fixture = Fixture()
        let more = (0..<10).map { index in
            fixture.session.addOrActivateProject(
                rootURL: WorkspaceSessionFixture.projectRootURL("more\(index)"),
                suggestedName: "more\(index)"
            )
        }
        let removed = more[0]
        fixture.session.removeProject(removed.id)
        #expect(fixture.session.recentProjectPaths.contains(removed.rootURL))

        // Every open project, again and again: twelve, past the cap of ten.
        let open = [fixture.a, fixture.b, fixture.c] + more.dropFirst()
        for _ in 0..<3 {
            for project in open {
                fixture.registry.show(project: project.id, in: fixture.session, from: fixture.primary, intent: .person)
            }
        }

        let recent = fixture.session.recentProjectPaths
        #expect(recent.count == WorkspaceSession.recentProjectPathsLimit)
        #expect(recent.contains(removed.rootURL))
        // The project used last comes first.
        #expect(recent.first == open.last?.rootURL)
        // A folder opened now comes first, and an open project's folder
        // makes room for it.
        let opened = fixture.session.addOrActivateProject(
            rootURL: WorkspaceSessionFixture.projectRootURL("opened"),
            suggestedName: "opened"
        )
        #expect(fixture.session.recentProjectPaths.first == opened.rootURL)
        #expect(fixture.session.recentProjectPaths.count == WorkspaceSession.recentProjectPathsLimit)
        #expect(fixture.session.recentProjectPaths.contains(removed.rootURL))
    }

    // MARK: - From outside a window

    @Test func backgroundPresentation_usesTheLastKeyWindow_forAnUnshownProject() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.c)
        fixture.registry.windowBecameKey(fixture.primary.id)
        fixture.registry.windowBecameKey(other.id)

        // As `AppState.openNotificationTarget` opens a tab.
        let shown = fixture.registry.present(project: fixture.b.id, in: fixture.session, from: fixture.registry.backgroundCommandTarget)
        if let shown {
            fixture.choose(fixture.bTab, in: shown)
        }

        #expect(shown === other)
        #expect(other.selection.shownProjectID == fixture.b.id)
        #expect(other.selection.activeTabID == fixture.bTab.id)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
        #expect(fixture.registry.windows.count == 2)
        fixture.expectInvariants()
    }

    @Test func menuBarOpen_switchesInPlace_andShowsAHiddenLastWindow() throws {
        let fixture = Fixture()
        let (store, navigator) = Self.attentionList(stopIn: fixture.bTab, of: fixture.b, fixture: fixture)
        let item = try #require(store.queue.items.first)
        // Every window closed: the last one is hidden.
        fixture.registry.close(fixture.primary.id, in: fixture.session)
        try #require(fixture.primary.isHidden && fixture.session.hiddenWindowIDs == [fixture.primary.id])

        store.focus(item, from: nil)

        #expect(!fixture.primary.isHidden)
        #expect(fixture.session.hiddenWindowIDs.isEmpty)
        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        #expect(fixture.primary.selection.activeTabID == fixture.bTab.id)
        #expect(fixture.registry.windows.map(\.id) == [fixture.primary.id])
        #expect(fixture.presenter.shown == [fixture.primary.id])
        withExtendedLifetime(navigator) {}
    }

    @Test func menuBarAnswerAndResume_switchNothing() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.c)
        fixture.registry.windowBecameKey(other.id)
        let aPane = try #require(fixture.aTab.splitTree.allLeafIDs().first)
        let bPane = try #require(fixture.bTab.splitTree.allLeafIDs().first)

        // "Resume Same Conversation": kept against the window that shows
        // the pane, else the one commands act on; nothing is shown.
        let resumedShown = MenuBarActions.resumeWindow(
            paneID: aPane,
            projectID: nil,
            session: fixture.session,
            registry: fixture.registry
        )
        let resumedElsewhere = MenuBarActions.resumeWindow(
            paneID: bPane,
            projectID: fixture.b.id,
            session: fixture.session,
            registry: fixture.registry
        )
        let resumedByProject = MenuBarActions.resumeWindow(
            paneID: UUID(),
            projectID: fixture.a.id,
            session: fixture.session,
            registry: fixture.registry
        )
        #expect(resumedShown === fixture.primary)
        #expect(resumedByProject === fixture.primary)
        #expect(resumedElsewhere === other)
        #expect(fixture.presenter.shown.isEmpty)
        #expect(other.selection.shownProjectID == fixture.c.id)

        // The menu bar's "Answer…" for a request of `b`: the card opens over the
        // window commands act on, brought back, on the project it shows.
        fixture.registry.hide(other.id)
        let approvals = ApprovalPresentationStore()
        let request = ApprovalPresentation.test()
        approvals.receive([request])

        #expect(fixture.registry.presentApprovalCardFromOutside(key: request.key, from: approvals))
        #expect(fixture.primary.approvalCard.isPresenting(request.key, in: approvals))
        #expect(!other.approvalCard.isOpen(in: approvals))
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(other.selection.shownProjectID == fixture.c.id)
        #expect(fixture.presenter.shown.isEmpty)
        #expect(fixture.session.projectViews.isEmpty)

        // Minimized, the window is taken out of the Dock for the card, and
        // still not switched.
        fixture.primary.approvalCard.dismiss()
        fixture.presenter.onScreen.remove(fixture.primary.id)
        #expect(fixture.registry.presentApprovalCardFromOutside(key: request.key, from: approvals))
        #expect(fixture.primary.approvalCard.isPresenting(request.key, in: approvals))
        #expect(fixture.presenter.shown == [fixture.primary.id])
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)

        // A request Weir can no longer answer on the card opens nothing,
        // and brings no window back.
        fixture.primary.approvalCard.dismiss()
        fixture.presenter.onScreen.remove(fixture.primary.id)
        fixture.presenter.shown = []
        approvals.ledger.record(.deadlinePassed, for: request.id, now: SuspendingClock.now)
        #expect(!fixture.registry.presentApprovalCardFromOutside(key: request.key, from: approvals))
        #expect(!fixture.primary.approvalCard.isOpen(in: approvals))
        #expect(fixture.presenter.shown.isEmpty)
    }

    @Test func aMinimizedWindow_switchedFromOutside_comesOutOfTheDock() {
        let fixture = Fixture()
        // Minimized: off screen, not hidden, still the window commands act on.
        fixture.presenter.onScreen.remove(fixture.primary.id)
        #expect(fixture.registry.backgroundCommandTarget === fixture.primary)

        // As a notification, a menu bar row, or ⌘J from the menu goes there.
        let shown = fixture.registry.present(project: fixture.b.id, in: fixture.session, from: nil)

        #expect(shown === fixture.primary)
        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        #expect(fixture.presenter.shown == [fixture.primary.id])
        #expect(fixture.presenter.isOnScreen(fixture.primary.id))

        // A window in front is left as it is.
        fixture.registry.show(project: fixture.c.id, in: fixture.session, from: fixture.primary, intent: .person)
        #expect(fixture.presenter.shown == [fixture.primary.id])
    }

    // MARK: - ⌘O

    @Test func openFolder_switchesThisWindow() async throws {
        let fixture = Fixture()
        let folder = WorkspaceSessionFixture.projectRootURL("opened")

        let resolved = WorkspaceSessionFixture.projectRootURL("repository")
        let shown = await SupervisionWindowActions.openProject(
            at: folder,
            from: fixture.primary,
            session: fixture.session,
            registry: fixture.registry,
            frecency: nil
        ) { candidate in
            #expect(candidate == folder)
            return resolved
        }

        let opened = try #require(fixture.session.projects.last)
        #expect(shown === fixture.primary)
        #expect(opened.rootURL == resolved.standardizedFileURL)
        #expect(fixture.primary.selection.shownProjectID == opened.id)
        #expect(fixture.primary.selection.activeContainerID == .project(opened.id))
        #expect(fixture.registry.windows.count == 1)
        #expect(fixture.session.projectViews[fixture.a.id]?.activeTabID == fixture.aTab.id)
        #expect(fixture.session.recentProjectPaths.first == resolved.standardizedFileURL)
        #expect(fixture.presenter.shown.isEmpty)
    }

    @Test func openFolder_afterThePersonMovedAway_doesNotSwitchBack() async throws {
        let fixture = Fixture()
        let folder = WorkspaceSessionFixture.projectRootURL("opened")

        // A notification takes the window to `b` while the folder is
        // resolved.
        let result = await SupervisionWindowActions.openProject(
            at: folder,
            from: fixture.primary,
            session: fixture.session,
            registry: fixture.registry,
            frecency: nil
        ) { url in
            fixture.choose(fixture.bTab, in: fixture.primary)
            return url
        }

        let opened = try #require(fixture.session.projects.last)
        #expect(result == nil)
        #expect(opened.rootURL == folder.standardizedFileURL)
        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        #expect(fixture.presenter.shown.isEmpty)
        #expect(fixture.primary.selection.activeTabID == fixture.bTab.id)
        #expect(fixture.registry.window(showingProject: opened.id, in: fixture.session) == nil)
        #expect(fixture.registry.windows.count == 1)
    }

    @Test func openFolder_fromAWindowThatClosed_switchesNothing() async throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.c)
        let folder = WorkspaceSessionFixture.projectRootURL("opened")

        let result = await SupervisionWindowActions.openProject(
            at: folder,
            from: other,
            session: fixture.session,
            registry: fixture.registry,
            frecency: nil
        ) { url in
            fixture.registry.close(other.id, in: fixture.session)
            return url
        }

        let opened = try #require(fixture.session.projects.last)
        #expect(result == nil)
        #expect(opened.rootURL == folder.standardizedFileURL)
        #expect(fixture.registry.window(showingProject: opened.id, in: fixture.session) == nil)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
        #expect(fixture.session.selection(other.id) == nil)
        #expect(fixture.registry.windows.map(\.id) == [fixture.primary.id])
        #expect(fixture.presenter.shown.isEmpty)
    }

}

extension WindowProjectSwitchTests {

    // MARK: - Folders

    /// The in-app Open command brings its hidden asking window back in place.
    @Test func inAppOpen_switchesTheHiddenAskingWindowInPlace() async throws {
        let fixture = Fixture()
        let primary = fixture.primary
        fixture.registry.hide(primary.id)
        let folder = WorkspaceSessionFixture.projectRootURL("opened")

        let shown = await SupervisionWindowActions.openProject(
            at: folder, from: primary, session: fixture.session, registry: fixture.registry, frecency: nil
        ) { $0 }

        let project = try #require(fixture.session.projects.first { $0.rootURL == folder.standardizedFileURL })
        #expect(shown === primary)
        #expect(fixture.registry.window(showingProject: project.id, in: fixture.session) === primary)
        #expect(!primary.isHidden)
        #expect(fixture.session.hiddenWindowIDs.isEmpty)
        #expect(fixture.registry.windows.map(\.id) == [primary.id])
        #expect(fixture.presenter.shown == [primary.id])
        #expect(fixture.session.projectViews[fixture.a.id]?.activeTabID == fixture.aTab.id)
    }

    @Test func anOpenedFolder_whoseProjectAHiddenWindowShows_bringsThatWindowBack() async throws {
        let fixture = Fixture()
        let primary = fixture.primary
        let target = try fixture.window(showing: fixture.b)
        fixture.registry.hide(target.id)
        fixture.registry.hide(primary.id)

        let shown = await SupervisionWindowActions.openProject(
            at: fixture.b.rootURL, from: primary, session: fixture.session, registry: fixture.registry, frecency: nil
        ) { $0 }

        #expect(shown === target)
        #expect(!target.isHidden)
        #expect(primary.isHidden)
        #expect(fixture.session.hiddenWindowIDs == [primary.id])
        #expect(fixture.registry.window(showingProject: fixture.b.id, in: fixture.session) === target)
        #expect(target.selection.activeTabID == fixture.bTab.id)
        #expect(primary.selection.activeTabID == fixture.aTab.id)
        #expect(fixture.session.windowIDs.count == 2)
        #expect(fixture.presenter.shown == [target.id])
    }

    /// A file is no project, nor is a package, which ⌘O cannot choose. A
    /// folder opens in a new window, leaving the project the window last
    /// used shows where it is.
    @Test func aFolderFromOutside_opensInANewWindow_andAFileOrAPackageIsLeftAlone() async throws {
        let fixture = Fixture()
        try await withTempDir { dir in
            let folder = dir.appending(path: "opened", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = dir.appending(path: "notes.txt")
            try Data().write(to: file)
            let package = dir.appending(path: "Tool.app", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let projectCount = fixture.session.projects.count
            let classification: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
            try #require(file.resourceValues(forKeys: classification).isDirectory == false)
            try #require(package.resourceValues(forKeys: classification).isPackage == true)
            try #require(folder.resourceValues(forKeys: classification).isDirectory == true)
            var resolved: [URL] = []

            await SupervisionWindowActions.openFolders(
                [file, package],
                session: fixture.session,
                registry: fixture.registry,
                frecency: nil
            ) {
                resolved.append($0)
                return $0
            }
            #expect(resolved.isEmpty)
            #expect(fixture.session.projects.count == projectCount)
            #expect(fixture.registry.windows.count == 1)

            await SupervisionWindowActions.openFolders(
                [file, folder],
                session: fixture.session,
                registry: fixture.registry,
                frecency: nil
            ) {
                resolved.append($0)
                return $0
            }

            #expect(resolved == [folder])
            let opened = try #require(fixture.session.projects.last)
            #expect(fixture.session.projects.count == projectCount + 1)
            #expect(opened.rootURL == folder.standardizedFileURL)
            #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
            let window = try #require(fixture.registry.window(showingProject: opened.id, in: fixture.session))
            #expect(window !== fixture.primary)
            #expect(fixture.registry.windows.count == 2)
            // It comes in front of the app the folder came from.
            #expect(fixture.presenter.shown == [window.id])
        }
    }

    /// The window the person was last in shows nothing: the folder fills
    /// it rather than opening another beside it.
    @Test func aFolderFromOutside_fillsTheEmptyWindowLastUsed() async throws {
        let fixture = Fixture()
        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)
        fixture.registry.windowBecameKey(empty.id)
        fixture.presenter.shown = []
        try await withTempDir { dir in
            let folder = dir.appending(path: "opened", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            await SupervisionWindowActions.openFolders(
                [folder],
                session: fixture.session,
                registry: fixture.registry,
                frecency: nil
            ) { $0 }

            let opened = try #require(fixture.session.projects.first { $0.rootURL == folder.standardizedFileURL })
            #expect(empty.selection.shownProjectID == opened.id)
            #expect(!empty.selection.isChoosingProject)
            #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
            #expect(Set(fixture.registry.windows.map(\.id)) == [fixture.primary.id, empty.id])
            #expect(fixture.presenter.shown == [empty.id])
        }
    }

    /// Every window closed, the last one hidden on its project: a folder
    /// from outside opens in a new window, and the hidden one closes,
    /// keeping its project, as New Window does. A folder of the hidden
    /// window's own project brings that window back instead.
    @Test func aFolderFromOutside_withEveryWindowClosed_opensANewWindow_andTheHiddenOneCloses() async throws {
        let fixture = Fixture()
        let hidden = fixture.primary
        try await withTempDir { dir in
            let folder = dir.appending(path: "opened", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let own = fixture.a.rootURL
            try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: own) }

            fixture.registry.close(hidden.id, in: fixture.session)
            await SupervisionWindowActions.openFolders(
                [own],
                session: fixture.session,
                registry: fixture.registry,
                frecency: nil
            ) { $0 }
            #expect(!hidden.isHidden)
            #expect(fixture.registry.windows.map(\.id) == [hidden.id])
            #expect(hidden.selection.shownProjectID == fixture.a.id)
            #expect(hidden.selection.activeTabID == fixture.aTab.id)

            fixture.registry.close(hidden.id, in: fixture.session)
            await SupervisionWindowActions.openFolders(
                [folder],
                session: fixture.session,
                registry: fixture.registry,
                frecency: nil
            ) { $0 }

            let opened = try #require(fixture.session.projects.first { $0.rootURL == folder.standardizedFileURL })
            let window = try #require(fixture.registry.window(showingProject: opened.id, in: fixture.session))
            #expect(window !== hidden)
            #expect(fixture.registry.windows.map(\.id) == [window.id])
            #expect(fixture.session.projectViews[fixture.a.id]?.activeTabID == fixture.aTab.id)
            #expect(fixture.registry.primary === window)
            #expect(fixture.session.primaryWindowID == window.id)
            #expect(fixture.session.selection(hidden.id) == nil)
            #expect(fixture.session.hiddenWindowIDs.isEmpty)
        }
    }

    /// A launch to open a folder, with two windows restored and none yet
    /// given the keyboard: the folder's new window is placed from the
    /// window restored in front, and neither restored window changes.
    @Test func aFolderOpenedAtLaunch_opensBesideTheWindowRestoredInFront() async throws {
        let fixture = Fixture()
        let front = try fixture.window(showing: fixture.c)
        fixture.session.frontWindowID = front.id
        fixture.registry.showRestoredWindows(of: fixture.session)
        #expect(fixture.presenter.shown == [fixture.primary.id, front.id])
        fixture.presenter.shown = []
        try await withTempDir { dir in
            let folder = dir.appending(path: "opened", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            await SupervisionWindowActions.openFolders(
                [folder],
                session: fixture.session,
                registry: fixture.registry,
                frecency: nil
            ) { $0 }

            let opened = try #require(fixture.session.projects.first { $0.rootURL == folder.standardizedFileURL })
            let window = try #require(fixture.registry.window(showingProject: opened.id, in: fixture.session))
            #expect(front.selection.shownProjectID == fixture.c.id)
            #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
            #expect(front.selection.activeTabID == fixture.cTab.id)
            #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
            #expect(fixture.presenter.openedFrom[window.id] == front.id)
            #expect(fixture.presenter.shown == [window.id])
            #expect(fixture.registry.windows.count == 3)
        }
    }

    /// Several folders at once: each in a window of its own, or the one
    /// that shows it already.
    @Test func severalFoldersFromOutside_eachComeToAWindow() async throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.c)
        fixture.registry.windowBecameKey(fixture.primary.id)
        try await withTempDir { dir in
            let first = dir.appending(path: "first", directoryHint: .isDirectory)
            let second = dir.appending(path: "second", directoryHint: .isDirectory)
            for folder in [first, second] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let shown = fixture.c.rootURL
            try FileManager.default.createDirectory(at: shown, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: shown) }

            var resolved: [URL] = []
            await SupervisionWindowActions.openFolders(
                [first, second, shown],
                session: fixture.session,
                registry: fixture.registry,
                frecency: nil
            ) {
                resolved.append($0)
                return $0
            }

            #expect(resolved == [first, second, shown])
            let firstProject = try #require(fixture.session.projects.first { $0.rootURL == first.standardizedFileURL })
            let secondProject = try #require(fixture.session.projects.first { $0.rootURL == second.standardizedFileURL })
            let windowOfFirst = try #require(fixture.registry.window(showingProject: firstProject.id, in: fixture.session))
            let windowOfSecond = try #require(fixture.registry.window(showingProject: secondProject.id, in: fixture.session))
            // The window the person was last in keeps its project.
            #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
            #expect(Set([windowOfFirst.id, windowOfSecond.id, fixture.primary.id, other.id]).count == 4)
            // A folder a window shows already brings that window forward.
            #expect(fixture.registry.window(showingProject: fixture.c.id, in: fixture.session) === other)
            #expect(fixture.presenter.shown == [windowOfFirst.id, windowOfSecond.id, other.id])
            #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
            #expect(other.selection.activeTabID == fixture.cTab.id)
            #expect(fixture.registry.windows.count == 4)
        }
    }

    // MARK: - All projects

    @Test func allProjectsCard_ofAProjectInAnotherWindow_saysOtherWindow() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.c)
        fixture.registry.hide(other.id)

        let cards = AllProjectsModel.cards(AllProjectsModel.Sources(
            session: fixture.session,
            window: fixture.primary.id,
            registry: fixture.registry,
            queue: AttentionQueue(),
            runtimes: [],
            approvals: ApprovalLedger(),
            pullRequest: { _ in nil },
            gitFacts: { _ in nil },
            locale: Locale(identifier: "en")
        ))

        let current = try #require(cards.first { $0.projectID == fixture.a.id })
        let unshown = try #require(cards.first { $0.projectID == fixture.b.id })
        let elsewhere = try #require(cards.first { $0.projectID == fixture.c.id })
        #expect(current.windowNote == .current)
        #expect(unshown.windowNote == nil)
        #expect(elsewhere.windowNote == .otherWindow)
    }

    @Test func projectMenuRows_ofAProjectInAnotherWindow_sayOtherWindow() throws {
        let fixture = Fixture()
        try fixture.window(showing: fixture.c)

        let rows = ProjectMenuModel(
            session: fixture.session,
            registry: fixture.registry,
            window: fixture.primary.selection,
            query: "",
            attentionQueue: AttentionQueue(),
            attention: AttentionState()
        ).rows

        #expect(rows.count == 3)
        #expect(Set(rows.map(\.id)) == [fixture.a.id, fixture.b.id, fixture.c.id])
        #expect(rows.filter(\.isCurrent).map(\.id) == [fixture.a.id])
        #expect(rows.filter(\.isInOtherWindow).map(\.id) == [fixture.c.id])
    }

    @Test func theProjectsInOtherWindows_countHiddenOnes_andNeverThisWindows() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.c)

        #expect(fixture.registry.projectsShown(besides: fixture.primary.id, in: fixture.session) == [fixture.c.id])
        #expect(fixture.registry.projectsShown(besides: other.id, in: fixture.session) == [fixture.a.id])
        #expect(fixture.registry.projectsShown(besides: nil, in: fixture.session) == [fixture.a.id, fixture.c.id])

        // Hidden, it still shows `c`: going there brings it back.
        fixture.registry.hide(other.id)
        #expect(fixture.registry.projectsShown(besides: fixture.primary.id, in: fixture.session) == [fixture.c.id])

        // Once it closes, no window shows `c`, and going there switches this one.
        fixture.registry.show(other.id)
        fixture.registry.close(other.id, in: fixture.session)
        #expect(fixture.registry.projectsShown(besides: fixture.primary.id, in: fixture.session).isEmpty)
        #expect(fixture.registry.projectsShown(besides: nil, in: fixture.session) == [fixture.a.id])
    }

    // MARK: - The window that shows the project

    /// An entry point to another project, used from the primary or, for
    /// those used from outside a window, with the primary the window last
    /// used.
    enum ProjectEntry: CaseIterable, Sendable {
        case projectMenu
        case paletteProjectRow
        case paletteTabRow
        case allProjectsCard
        case needsAttentionList
        case nextAttention
        case notification
        case menuBarOpen
        case openFolder
    }

    /// Shown or hidden, the window that shows the project is the one
    /// brought forward.
    @Test(arguments: ProjectEntry.allCases, [false, true])
    func everyEntry_raisesTheWindowThatShowsTheProject_insteadOfSwitching(
        _ entry: ProjectEntry,
        isOtherWindowHidden: Bool
    ) async throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        fixture.registry.windowBecameKey(other.id)
        fixture.registry.windowBecameKey(fixture.primary.id)
        if isOtherWindowHidden {
            fixture.registry.hide(other.id)
        }
        fixture.presenter.shown = []
        let (store, navigator) = Self.attentionList(stopIn: fixture.bTab, of: fixture.b, fixture: fixture)
        let item = try #require(store.queue.items.first)

        try await Self.go(to: fixture.b, by: entry, fixture: fixture, store: store, item: item)

        #expect(fixture.presenter.shown == [other.id])
        #expect(!other.isHidden)
        #expect(!fixture.session.hiddenWindowIDs.contains(other.id))
        #expect(other.selection.shownProjectID == fixture.b.id)
        #expect(other.selection.activeTabID == fixture.bTab.id)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
        #expect(fixture.registry.windows.count == 2)
        #expect(fixture.session.projectViews.isEmpty)
        fixture.expectInvariants()
        withExtendedLifetime(navigator) {}
    }

    /// Goes to `project`, whose session is `fixture.bTab`, by `entry`, as
    /// the app does.
    private static func go(
        to project: Project,
        by entry: ProjectEntry,
        fixture: Fixture,
        store: AttentionQueueStore,
        item: AttentionItem
    ) async throws {
        let primary = fixture.primary
        switch entry {
        case .projectMenu:
            fixture.registry.show(project: project.id, in: fixture.session, from: primary, intent: .person)
        case .paletteProjectRow:
            let handling = SupervisionWindowActions.runProjectRow(
                .activateProject(project.id), in: primary, session: fixture.session, registry: fixture.registry, frecency: nil
            )
            #expect(handling == .handled)
        case .paletteTabRow:
            let handling = SupervisionWindowActions.runProjectRow(
                .jumpToTab(fixture.bTab.id), in: primary, session: fixture.session, registry: fixture.registry, frecency: nil
            )
            #expect(handling == .handled)
        case .allProjectsCard:
            // As `AllProjectsActions.open` opens a card with no item.
            let target = try #require(fixture.registry.show(project: project.id, in: fixture.session, from: primary, intent: .person))
            fixture.session.setActiveContainer(.project(project.id), in: target.id, intent: .person)
        case .needsAttentionList:
            store.focus(item, from: primary)
        case .nextAttention:
            store.jump(forward: true, in: primary)
        case .notification:
            let shown = try #require(fixture.registry.present(
                project: project.id,
                in: fixture.session,
                from: fixture.registry.backgroundCommandTarget
            ))
            fixture.choose(fixture.bTab, in: shown)
        case .menuBarOpen:
            store.focus(item, from: nil)
        case .openFolder:
            await SupervisionWindowActions.openProject(
                at: project.rootURL,
                from: primary,
                session: fixture.session,
                registry: fixture.registry,
                frecency: nil
            ) { $0 }
        }
    }

    /// Makes the Needs Attention list with one stopped agent, in `tab` of
    /// `project`. The navigator is held by the caller, because the list
    /// holds it weakly.
    private static func attentionList(
        stopIn tab: Tab,
        of project: Project,
        fixture: Fixture
    ) -> (store: AttentionQueueStore, navigator: SessionAttentionNavigator) {
        AttentionQueueFixture.stopped(in: tab, projectID: project.id, session: fixture.session, registry: fixture.registry)
    }
}
