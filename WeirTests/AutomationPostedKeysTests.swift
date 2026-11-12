// AutomationPostedKeysTests.swift
// Weir — where a key the verification client posts may land, as `state` reports it and the gate applies it.

#if DEBUG && WEIR_AUTOMATION

    import AppKit
    import Testing
    @testable import Weir

    @MainActor
    struct AutomationPostedKeysTests {
        private func window(focusing view: NSView? = nil) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: window.contentLayoutRect)
            window.contentView = content
            if let view {
                content.addSubview(view)
                #expect(window.makeFirstResponder(view))
            }
            return window
        }

        @Test func refusal_aSheetUp_refusesWhateverHoldsTheKeyboard() {
            #expect(AutomationPostedKeys.refusal(hasSheet: true, firstResponder: NSTextField()) == .sheet)
            #expect(AutomationPostedKeys.refusal(hasSheet: true, firstResponder: nil) == .sheet)
        }

        @Test func refusal_aControlHoldsTheKeyboard_lets() {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
            let window = window(focusing: field)
            defer { window.close() }

            #expect(AutomationPostedKeys.refusal(hasSheet: false, firstResponder: window.firstResponder) == nil)
            #expect(AutomationPostedKeys.mayDeliver(to: window) { _ in true })
        }

        @Test func refusal_theWindowHoldsTheKeyboard_refusesAsNothingHoldingIt() {
            let window = window()
            defer { window.close() }

            #expect(AutomationPostedKeys.refusal(hasSheet: false, firstResponder: window) == .nothingHoldsKeyboard)
            #expect(AutomationPostedKeys.refusal(hasSheet: false, firstResponder: nil) == .nothingHoldsKeyboard)
            #expect(!AutomationPostedKeys.mayDeliver(to: window) { _ in true })
        }

        @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
        func refusal_aPaneHoldsTheKeyboard_refuses() throws {
            let ghosttyApp = try #require(GhosttyApp.placeholder.target)
            let surface = PaneHostRepresentable.makeSurfaceView(ghosttyApp: ghosttyApp, environment: [:])
            let window = window(focusing: surface)
            defer { window.close() }

            #expect(AutomationPostedKeys.refusal(hasSheet: false, firstResponder: surface) == .pane)
            #expect(!AutomationPostedKeys.mayDeliver(to: window) { _ in true })
        }

        @Test func mayDeliver_aWindowThatIsNotAProjectWindow_refuses() {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
            let window = window(focusing: field)
            defer { window.close() }

            #expect(!AutomationPostedKeys.mayDeliver(to: window) { _ in false })
            #expect(!AutomationPostedKeys.mayDeliver(to: nil) { _ in true })
        }

        @Test func refusal_aControlHoldsTheKeyboard_stillRefusesWhileSettingsOrTheQuickTerminalIsShown() {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
            let window = window(focusing: field)
            defer { window.close() }

            #expect(AutomationPostedKeys
                .refusal(isSettingsShown: true, isQuickTerminalShown: true, shownWindows: [window]) == .settingsShown)
            #expect(AutomationPostedKeys
                .refusal(isSettingsShown: false, isQuickTerminalShown: true, shownWindows: [window]) == .quickTerminalShown)
            #expect(AutomationPostedKeys.refusal(isSettingsShown: false, isQuickTerminalShown: false, shownWindows: [window]) == nil)
        }

        @Test func refusal_theWindowsOwnRefusal_comesBeforeSettings() {
            let window = window()
            defer { window.close() }

            #expect(AutomationPostedKeys
                .refusal(isSettingsShown: true, isQuickTerminalShown: true, shownWindows: [window]) == .nothingHoldsKeyboard)
        }

        @Test func refusal_noWindowOrSeveral_refusesEvenWhenAppKitHasNoWindowForOne() {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
            let window = window(focusing: field)
            defer { window.close() }

            for shown: [NSWindow?] in [[], [window, window], [window, nil], [nil]] {
                #expect(AutomationPostedKeys
                    .refusal(isSettingsShown: false, isQuickTerminalShown: false, shownWindows: shown) == .notOneWindow)
            }
        }
    }

#endif
