// MenuBarItemControllerTests.swift
// Weir — status button accessibility actions and the menu bar item's lifetime.

import AppKit
import SwiftUI
import Synchronization
import Testing
@testable import Weir

@MainActor
@Suite(.serialized)
struct MenuBarItemControllerTests {
    private static func controller(
        content: AnyView,
        popover: NSPopover = NSPopover(),
        onRemoval: @escaping () -> Void
    ) -> MenuBarItemController {
        MenuBarItemController(
            content: content,
            popover: popover,
            makeStatusItem: { MenuBarStatusItemProbe() },
            removeStatusItem: { _ in },
            onRemoval: onRemoval
        )
    }

    @Test func accessibilityPress_opensAndClosesWithoutAMouseEvent() throws {
        let popover = MenuBarPopoverProbe()
        let controller = Self.controller(content: AnyView(Text("Attention")), popover: popover, onRemoval: {})
        defer { controller.remove() }
        controller.update(isInserted: true, image: NSImage(), label: "Weir, Needs Attention 1")
        let button = try #require(controller.statusItem?.button)

        // An unattached button can return false after dispatching its action.
        // The dedicated AX harness checks the real item's return and popover.
        _ = button.accessibilityPerformPress()
        #expect(popover.shows == 1)
        #expect(popover.anchor === button)
        #expect(popover.isShown)

        _ = button.accessibilityPerformPress()
        #expect(popover.closes == 1)
        #expect(!popover.isShown)

        _ = button.accessibilityPerformPress()
        #expect(popover.shows == 2)
        #expect(popover.isShown)
    }

    @Test func updates_keepTheItemAndRefreshItsSpokenLabel() throws {
        let controller = Self.controller(content: AnyView(EmptyView()), onRemoval: {})
        defer { controller.remove() }
        let image = NSImage()
        controller.update(isInserted: true, image: image, label: "Weir, Needs Attention 1")
        let item = try #require(controller.statusItem)
        controller.update(isInserted: true, image: image, label: "Weir, 要対応 2")

        #expect(controller.statusItem === item)
        #expect(item.button?.accessibilityLabel() == "Weir, 要対応 2")
        #expect(item.button?.image?.accessibilityDescription == "Weir, 要対応 2")
    }

    @Test func turningTheItemOff_closesItAndDoesNotReportADrag() throws {
        var removals = 0
        let popover = MenuBarPopoverProbe()
        let controller = Self.controller(content: AnyView(EmptyView()), popover: popover, onRemoval: { removals += 1 })
        defer { controller.remove() }
        controller.update(isInserted: true, image: NSImage(), label: "Weir")
        let button = try #require(controller.statusItem?.button)
        _ = button.accessibilityPerformPress()
        #expect(popover.isShown)

        controller.update(isInserted: false, image: NSImage(), label: "Weir")
        #expect(controller.statusItem == nil)
        #expect(!popover.isShown)
        #expect(removals == 0)

        controller.update(isInserted: true, image: NSImage(), label: "Weir")
        let replacement = try #require(controller.statusItem?.button)
        _ = replacement.accessibilityPerformPress()
        #expect(popover.shows == 2)
    }

    @Test func aDragRemoval_reportsTheSettingChangeAndClosesTheList() throws {
        var removals = 0
        let popover = MenuBarPopoverProbe()
        let controller = Self.controller(content: AnyView(EmptyView()), popover: popover, onRemoval: { removals += 1 })
        defer { controller.remove() }
        controller.update(isInserted: true, image: NSImage(), label: "Weir")
        let item = try #require(controller.statusItem)
        let button = try #require(item.button)
        _ = button.accessibilityPerformPress()
        item.isVisible = false
        #expect(removals == 1)
        #expect(!popover.isShown)

        controller.update(isInserted: false, image: NSImage(), label: "Weir")
        controller.update(isInserted: true, image: NSImage(), label: "Weir")
        let replacement = try #require(controller.statusItem)
        #expect(replacement.isVisible)
        _ = replacement.button?.accessibilityPerformPress()
        #expect(popover.isShown)
    }
}

/// Observes native button dispatch without opening a window over the test run.
@MainActor
private final class MenuBarPopoverProbe: NSPopover {
    var shows = 0
    var closes = 0
    private var hasOpened = false
    /// The status button passed to the most recent show, or nil before it.
    weak var anchor: NSView?

    override var isShown: Bool {
        hasOpened
    }

    override func show(relativeTo _: NSRect, of positioningView: NSView, preferredEdge _: NSRectEdge) {
        shows += 1
        hasOpened = true
        anchor = positioningView
    }

    override func performClose(_: Any?) {
        closes += 1
        hasOpened = false
    }
}

/// An unattached item whose visibility never reaches AppKit user defaults.
@MainActor
private final class MenuBarStatusItemProbe: NSStatusItem {
    private let probeButton = NSStatusBarButton(frame: .zero)
    private nonisolated let visibleState = Mutex(true)
    private nonisolated let nameState = Mutex("")

    override var button: NSStatusBarButton? {
        probeButton
    }

    override var isVisible: Bool {
        // NSStatusItem exposes visibility and autosave accessors as nonisolated.
        get { visibleState.withLock { $0 } }
        set { visibleState.withLock { $0 = newValue } }
    }

    override var autosaveName: NSStatusItem.AutosaveName! {
        get { nameState.withLock { $0 } }
        set { nameState.withLock { $0 = newValue ?? "" } }
    }
}
