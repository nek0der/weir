// ProjectWindowPresenterTests.swift
// Weir — app-owned main windows: shown, closed or hidden when the last, never restored.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Weir
@testable import WeirDomain

@Suite(.hostsWindows)
@MainActor
struct ProjectWindowPresenterTests {
    @MainActor
    private struct Fixture {
        let session: WorkspaceSession
        let registry: WindowRegistry
        let presenter: ProjectWindowPresenter

        init(initialContentSize: NSSize = ProjectWindowController.initialContentSize) {
            session = WorkspaceSession()
            registry = WindowRegistry(primary: session.primarySelection)
            presenter = ProjectWindowPresenter(
                session: session,
                registry: registry,
                initialContentSize: initialContentSize
            ) { _ in AnyView(EmptyView()) }
            registry.presenter = presenter
        }

        var primary: ProjectWindowState {
            registry.primary
        }

        /// Shows the primary and returns the window that appeared for it.
        func showPrimary() -> NSWindow? {
            registry.show(primary.id)
            return presenter.nsWindow(for: primary.id)
        }

        /// Shows the primary on a project of its own, so choosing another
        /// project brings that project's window rather than switching the
        /// primary.
        func showPrimaryOnItsOwnProject() throws -> NSWindow {
            let own = addProject("own")
            session.setActiveContainer(.project(own.id))
            return try #require(showPrimary())
        }

        func addProject(_ name: String) -> Project {
            session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL(name), suggestedName: name)
        }

        /// Opens `project` in a new window, asked from `source`, and returns
        /// it with the window that appeared for it.
        func openInNewWindow(
            _ project: Project,
            from source: ProjectWindowState?
        ) throws -> (state: ProjectWindowState, window: NSWindow) {
            let state = try #require(registry.openInNewWindow(project: project.id, in: session, from: source))
            let window = try #require(presenter.nsWindow(for: state.id))
            return (state, window)
        }
    }

    /// Each window opened from the primary steps on from the last one
    /// placed, on the primary's screen and inside it.
    @Test func windowsOpenedOneAfterAnother_fromOneWindow_eachStepOn() throws {
        // Small enough to leave room for every step on any screen. At the
        // usual size a CI runner's has none, every step wraps back to the
        // top-left, and the windows share it. The wrap itself is
        // `theCascade_stepsFromTheLastWindowPlaced_andWrapsAtTheScreensEdge`.
        let fixture = Fixture(initialContentSize: NSSize(width: 400, height: 300))
        let registry = fixture.registry
        let primaryWindow = try fixture.showPrimaryOnItsOwnProject()
        var opened: [ProjectWindowState] = []
        defer {
            for window in opened {
                registry.hide(window.id)
            }
            registry.hide(registry.primary.id)
        }
        var frames: [CGRect] = []
        for name in ["first", "second", "third"] {
            let (state, window) = try fixture.openInNewWindow(fixture.addProject(name), from: registry.primary)
            opened.append(state)
            frames.append(window.frame)
            #expect(window.screen == primaryWindow.screen)
        }

        let visible = try #require(primaryWindow.screen?.visibleFrame)
        let origins = [primaryWindow.frame.origin] + frames.map(\.origin)
        #expect(Set(origins.map { "\($0.x),\($0.y)" }).count == 4, "no window lands on another")
        for frame in frames {
            #expect(visible.contains(frame) || frame.width > visible.width || frame.height > visible.height)
        }
    }

    /// A window opened from another takes its size, not the size a window
    /// opens at.
    @Test func aWindowOpenedFromAnother_takesItsSize() throws {
        let fixture = Fixture(initialContentSize: NSSize(width: 400, height: 300))
        let registry = fixture.registry
        let primaryWindow = try fixture.showPrimaryOnItsOwnProject()
        var opened: ProjectWindowState?
        defer {
            if let opened {
                registry.hide(opened.id)
            }
            registry.hide(registry.primary.id)
        }
        let initialSize = primaryWindow.frame.size
        primaryWindow.setFrame(NSRect(origin: primaryWindow.frame.origin, size: NSSize(width: 520, height: 410)), display: false)
        try #require(primaryWindow.frame.size != initialSize)

        let (state, window) = try fixture.openInNewWindow(fixture.addProject("sized"), from: registry.primary)
        opened = state

        #expect(window.frame.size == primaryWindow.frame.size)
    }

    @Test func theCascade_stepsFromTheLastWindowPlaced_andWrapsAtTheScreensEdge() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let step = CGSize(width: 20, height: 22)
        let size = CGSize(width: 400, height: 300)
        let origin = NSPoint(x: 100, y: 700)
        let cascade = { (previous: NSPoint?) in
            ProjectWindowPresenter.cascadeTopLeft(after: previous, from: origin, step: step, size: size, inside: visible)
        }

        let first = cascade(nil)
        #expect(first == NSPoint(x: 120, y: 678))
        let second = cascade(first)
        #expect(second == NSPoint(x: 140, y: 656))
        // A step past the right or bottom edge starts again near the
        // screen's top-left.
        #expect(cascade(NSPoint(x: 590, y: 600)) == NSPoint(x: 20, y: 778))
        #expect(cascade(NSPoint(x: 100, y: 310)) == NSPoint(x: 20, y: 778))
    }

    @Test func aWindowPlaced_isKeptInsideTheScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        // Past the right and bottom edges: moved back in.
        #expect(ProjectWindowPresenter.kept(CGRect(x: 900, y: -50, width: 400, height: 300), inside: visible)
            == CGRect(x: 600, y: 0, width: 400, height: 300))
        // Inside already: left as it is.
        #expect(ProjectWindowPresenter.kept(CGRect(x: 10, y: 20, width: 400, height: 300), inside: visible)
            == CGRect(x: 10, y: 20, width: 400, height: 300))
        // Taller than the screen: its top edge at the screen's.
        #expect(ProjectWindowPresenter.kept(CGRect(x: 10, y: 100, width: 400, height: 900), inside: visible)
            == CGRect(x: 10, y: -100, width: 400, height: 900))
    }

    @Test func show_opensTheWindowAndHide_ordersItOut() {
        let fixture = Fixture()
        defer { fixture.registry.hide(fixture.primary.id) }

        fixture.registry.show(fixture.primary.id)
        #expect(fixture.presenter.isOnScreen(fixture.primary.id))
        #expect(!fixture.primary.isHidden)

        fixture.registry.hide(fixture.primary.id)
        #expect(!fixture.presenter.isOnScreen(fixture.primary.id))
        #expect(fixture.primary.isHidden)
    }

    @Test func closing_hidesAndKeepsTheSameWindow() throws {
        let fixture = Fixture()
        defer { fixture.registry.hide(fixture.primary.id) }
        let window = try #require(fixture.showPrimary())

        let controller = try #require(window.delegate as? ProjectWindowController)
        #expect(controller.windowShouldClose(window) == false)
        #expect(fixture.primary.isHidden)
        #expect(!window.isVisible)

        fixture.registry.show(fixture.primary.id)
        #expect(window.isVisible)
        #expect(window.delegate === controller)
    }

    @Test func closingAWindowBesideAnother_releasesItsControllerAndWindow() async throws {
        let fixture = Fixture()
        let registry = fixture.registry
        let primaryWindow = try fixture.showPrimaryOnItsOwnProject()
        let project = fixture.addProject("close")
        defer { registry.hide(registry.primary.id) }
        weak var closedController: ProjectWindowController?
        weak var closedWindow: NSWindow?
        var opened: WindowID?
        // In a pool of its own, so what AppKit hands back autoreleased
        // (the window list, the window itself) is let go with it.
        try autoreleasepool {
            let (other, otherWindow) = try fixture.openInNewWindow(project, from: nil)
            opened = other.id
            let controller = try #require(otherWindow.delegate as? ProjectWindowController)
            closedController = controller
            closedWindow = otherWindow
            #expect(fixture.presenter.windowIDs == [registry.primary.id, other.id])

            // Its close button: the window closes for good, not hidden.
            #expect(controller.windowShouldClose(otherWindow) == false)

            #expect(!otherWindow.isVisible)
            #expect(otherWindow.contentViewController == nil)
        }
        let otherID = try #require(opened)

        #expect(registry.window(otherID) == nil)
        #expect(fixture.presenter.windowIDs == [registry.primary.id])
        #expect(!fixture.presenter.isOnScreen(otherID))
        #expect(primaryWindow.isVisible)
        // Let go once AppKit is out of the close button's call.
        await pollUntil(timeout: .seconds(2), interval: .milliseconds(20)) { closedController == nil }
        #expect(closedController == nil)
        // Nothing of the app's holds the window any longer. The test host
        // keeps the NSWindow itself alive (it stays in NSApp.windows, off
        // screen), where an app of AppKit alone frees it at once, so what
        // the app would hold it by is checked instead.
        if let window = closedWindow {
            #expect(window.windowController == nil)
            #expect(window.delegate == nil)
            #expect(window.contentViewController == nil)
            #expect(!window.isVisible)
        }

        // The last window left hides rather than closes.
        let primaryController = try #require(primaryWindow.delegate as? ProjectWindowController)
        #expect(primaryController.windowShouldClose(primaryWindow) == false)
        #expect(registry.primary.isHidden)
        #expect(fixture.presenter.windowIDs == [registry.primary.id])
    }

    @Test func theWindowIsNeverRestoredOrReleasedOnClose() throws {
        let fixture = Fixture()
        defer { fixture.registry.hide(fixture.primary.id) }
        let window = try #require(fixture.showPrimary())

        #expect(!window.isRestorable)
        #expect(!window.isReleasedWhenClosed)
        #expect(window.tabbingMode == .disallowed)
        #expect(window.styleMask.contains(.fullSizeContentView))
    }

    @Test func aWindowWithoutASelection_isNotShown() {
        let fixture = Fixture()
        let stranger = ProjectWindowState(id: WindowID())

        fixture.presenter.show(stranger, openedFrom: nil)

        #expect(!fixture.presenter.isOnScreen(stranger.id))
        #expect(fixture.presenter.windowIDs.isEmpty)
    }

    @Test func eachProjectsWindow_isAWindowOfItsOwn_hiddenAlone() throws {
        let fixture = Fixture()
        let registry = fixture.registry
        let primaryWindow = try fixture.showPrimaryOnItsOwnProject()
        let (other, otherWindow) = try fixture.openInNewWindow(fixture.addProject("presenter"), from: nil)
        defer {
            registry.hide(other.id)
            registry.hide(registry.primary.id)
        }

        #expect(otherWindow !== primaryWindow)
        #expect((otherWindow.delegate as? ProjectWindowController)?.windowID == other.id)

        registry.hide(other.id)
        #expect(!otherWindow.isVisible)
        #expect(primaryWindow.isVisible)
        #expect(fixture.presenter.isOnScreen(registry.primary.id))
    }

    @Test func aHiddenProjectWindow_comesBackOnScreen_whenItsProjectIsChosenAgain() throws {
        let fixture = Fixture()
        let (session, registry) = (fixture.session, fixture.registry)
        _ = try fixture.showPrimaryOnItsOwnProject()
        let project = fixture.addProject("reraise")
        let (other, otherWindow) = try fixture.openInNewWindow(project, from: nil)
        defer {
            registry.hide(other.id)
            registry.hide(registry.primary.id)
        }
        registry.hide(other.id)
        #expect(!otherWindow.isVisible)

        registry.connectProjectSwitching(of: session)
        let again = registry.show(project: project.id, in: session, from: registry.primary, intent: .person)

        #expect(again === other)
        #expect(otherWindow.isVisible)
        #expect(fixture.presenter.nsWindow(for: other.id) === otherWindow)
        #expect(fixture.presenter.windowIDs == [registry.primary.id, other.id])
    }
}
