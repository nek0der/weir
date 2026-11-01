// KeyboardHandoffTests.swift
// Weir — who keeps the keyboard when a surface closes, and that a surface opening takes it only after two turns.

import AppKit
import Testing
@testable import Weir

@MainActor
struct KeyboardHandoffTests {
    @Test func aTerminal_alwaysKeepsTheKeyboard() {
        #expect(!KeyboardHandoff.returnsKeyboard(from: .terminal, keeper: .terminal))
        #expect(!KeyboardHandoff.returnsKeyboard(from: .terminal, keeper: .terminalOrTextField))
    }

    @Test func aTextField_keepsItOnlyWhereTheClosingSurfaceHadNone() {
        // A dropdown's or sheet's own field, still fading out.
        #expect(KeyboardHandoff.returnsKeyboard(from: .textField, keeper: .terminal))
        // A field the person went to once a rename field was gone.
        #expect(!KeyboardHandoff.returnsKeyboard(from: .textField, keeper: .terminalOrTextField))
    }

    @Test func anythingElse_givesItToTheTerminal() {
        #expect(KeyboardHandoff.returnsKeyboard(from: .other, keeper: .terminal))
        #expect(KeyboardHandoff.returnsKeyboard(from: .other, keeper: .terminalOrTextField))
    }

    @Test func aSurfaceOpening_takesTheKeyboardAfterTwoTurns() async {
        let clock = TurnClock()
        KeyboardHandoff.afterResponderSettles { clock.turnsWhenTaken = clock.turns }
        DispatchQueue.main.async {
            clock.turns += 1
            DispatchQueue.main.async { clock.turns += 1 }
        }
        await KeyboardHandoff.responderSettled()
        await KeyboardHandoff.responderSettled()
        // Queued before the counter's turns, the request runs after the
        // counter's first turn and before its second: two turns in.
        #expect(clock.turnsWhenTaken == 1)
    }

    /// A window whose text field holds the keys, as the palette's and the
    /// search bar's do when Esc reaches them, over `paneID`'s terminal.
    private func windowWithFieldFocused(
        over paneID: UUID,
        registry: SurfaceRegistry
    ) throws -> (window: NSWindow, surface: SurfaceView) {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let surface = PaneHostRepresentable.makeSurfaceView(ghosttyApp: ghosttyApp, environment: [:])
        registry.register(surface, for: paneID)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentLayoutRect)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        content.addSubview(surface)
        content.addSubview(field)
        window.contentView = content
        #expect(window.makeFirstResponder(field))
        #expect(window.firstResponder !== surface)
        return (window, surface)
    }

    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func closingThePalette_givesTheKeyboardToTheFocusedPane() throws {
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        let registry = SurfaceRegistry()
        let (window, surface) = try windowWithFieldFocused(over: paneID, registry: registry)
        defer { window.close() }
        session.commandPaletteState = CommandPaletteState(locale: Locale(identifier: "en"), windowID: session.primaryWindowID)

        KeyboardHandoff.closePalette(session: session, registry: registry)

        #expect(session.commandPaletteState == nil)
        #expect(window.firstResponder === surface)
    }

    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func closingAPaneSearch_givesTheKeyboardToThatPane() throws {
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        let registry = SurfaceRegistry()
        let (window, surface) = try windowWithFieldFocused(over: paneID, registry: registry)
        defer { window.close() }
        session.paneSearchStates[paneID] = PaneSearchState()

        KeyboardHandoff.closePaneSearch(paneID: paneID, session: session, registry: registry)

        #expect(session.paneSearchStates[paneID] == nil)
        #expect(window.firstResponder === surface)
    }
}

/// Counts turns of the main queue, for the handoff test.
@MainActor
private final class TurnClock {
    var turns = 0
    var turnsWhenTaken: Int?
}
