// MenuBarItemController.swift
// Weir — the accessible status button and the popover hosting the SwiftUI attention list.

import AppKit
import SwiftUI

/// The AppKit boundary for opening the SwiftUI list through either a mouse
/// press or AXPress. A window-style `MenuBarExtra` accepted AXPress without
/// opening its window on macOS 27.2; a status button sends its action for both.
@MainActor
final class MenuBarItemController: NSObject, NSPopoverDelegate {
    /// Absent while the person has turned the menu bar item off.
    private(set) var statusItem: NSStatusItem?
    let popover: NSPopover
    private let onRemoval: () -> Void
    private let makeStatusItem: () -> NSStatusItem
    private let removeStatusItem: (NSStatusItem) -> Void
    /// Watches Command-drag removal only while the item is inserted.
    private var visibilityObservation: NSKeyValueObservation?

    init(
        content: AnyView,
        popover: NSPopover = NSPopover(),
        makeStatusItem: @escaping () -> NSStatusItem = { NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) },
        removeStatusItem: @escaping (NSStatusItem) -> Void = { NSStatusBar.system.removeStatusItem($0) },
        onRemoval: @escaping () -> Void
    ) {
        self.popover = popover
        self.onRemoval = onRemoval
        self.makeStatusItem = makeStatusItem
        self.removeStatusItem = removeStatusItem
        super.init()
        popover.behavior = .transient
        popover.animates = false
        let hosting = NSHostingController(rootView: content)
        // The list measures its rows after mounting and changes as waits end.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.delegate = self
    }

    convenience init(state: AppState) {
        let menuWindow = MenuBarActions.MenuWindow()
        self.init(
            content: AnyView(MenuBarContent(state: state, menuWindow: menuWindow)),
            onRemoval: { state.settingsStore.settings.general.showMenuBarExtra = false }
        )
        menuWindow.dismiss = { [weak self] in self?.close() }
        let refresh: @MainActor () -> Void = { [weak self] in
            let model = MenuBarLabelModel(state.attentionQueue.queue.counts())
            self?.update(
                isInserted: state.settingsStore.settings.general.showMenuBarExtra,
                image: MenuBarLampImage.image(model.lamp),
                label: model.accessibilityLabel(locale: state.settingsStore.appLocale)
            )
        }
        refresh()
        observeRepeatedly { [weak state] in
            _ = state?.settingsStore.settings.general.showMenuBarExtra
            _ = state?.settingsStore.appLocale
            _ = state?.attentionQueue.queue
        } onChange: {
            refresh()
        }
    }

    /// Updates the icon and spoken count without replacing an inserted item.
    func update(isInserted: Bool, image: NSImage, label: String) {
        guard isInserted else {
            remove()
            return
        }
        if statusItem == nil {
            let item = makeStatusItem()
            statusItem = item
            item.autosaveName = "WeirAttention"
            // The setting owns insertion, even if AppKit saved a hidden item.
            item.isVisible = true
            item.behavior = [.removalAllowed]
            item.button?.target = self
            item.button?.action = #selector(toggle(_:))
            visibilityObservation = item.observe(\.isVisible, options: [.new]) { [weak self] _, change in
                let isVisible = change.newValue ?? true
                MainActor.assumeIsolated {
                    guard let self, !isVisible else { return }
                    self.close()
                    self.onRemoval()
                }
            }
        }
        image.accessibilityDescription = label
        statusItem?.button?.image = image
        statusItem?.button?.setAccessibilityLabel(label)
        statusItem?.isVisible = true
    }

    /// Closes the popover through its owner, including from SwiftUI row actions.
    func close() {
        popover.performClose(nil)
    }

    /// Releases the status item without treating a setting change as a drag.
    func remove() {
        visibilityObservation = nil
        close()
        if let statusItem {
            removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    @objc private func toggle(_: Any?) {
        if popover.isShown {
            close()
        } else if let button = statusItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            button.highlight(true)
        }
    }

    func popoverDidClose(_: Notification) {
        statusItem?.button?.highlight(false)
    }
}

/// Keeps the list's locale live while the AppKit host is retained between presses.
private struct MenuBarContent: View {
    let state: AppState
    let menuWindow: MenuBarActions.MenuWindow

    var body: some View {
        SupervisionMenuBarContent(state: state, menuWindow: menuWindow)
            .environment(\.locale, state.settingsStore.appLocale)
    }
}
