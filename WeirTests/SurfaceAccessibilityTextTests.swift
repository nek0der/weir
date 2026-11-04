// SurfaceAccessibilityTextTests.swift
// Weir — text an accessibility client writes into a pane reaches the terminal, and several lines arrive as a paste.

import AppKit
import GhosttyKit
import Testing
@testable import Weir

@Suite("Surface accessibility text")
@MainActor
struct SurfaceAccessibilityTextTests {

    @Test func aLineWithNoControlCharacter_isTyped() {
        #expect(AccessibilityTextRoute("echo hello") == .typed("echo hello"))
        #expect(AccessibilityTextRoute("日本語のプロンプト") == .typed("日本語のプロンプト"))
    }

    @Test func nothingToWrite_hasNoRoute() {
        #expect(AccessibilityTextRoute(nil) == nil)
        #expect(AccessibilityTextRoute("") == nil)
    }

    /// Typed, a newline would be a Return, and a shell would run the line
    /// before anyone saw it; as a paste, it meets bracketed paste or the
    /// paste confirmation.
    @Test(arguments: ["echo a\necho b", "echo a\n", "\t", "\u{1B}[A"])
    func textWithAControlCharacter_isPasted(text: String) {
        #expect(AccessibilityTextRoute(text) == .pasted(text))
    }

    /// A line break alone is how a client presses Return, and it carries no
    /// text that could run unseen.
    @Test(arguments: ["\n", "\r", "\r\n"])
    func aLineBreakAlone_isTheReturnKey(text: String) {
        #expect(AccessibilityTextRoute(text) == .returnKey)
    }

    /// A paste refuses a carriage return, so a client's other line endings
    /// would drop the whole text.
    @Test func carriageReturns_arePastedAsNewlines() throws {
        #expect(AccessibilityTextRoute("a\r\nb\rc") == .pasted("a\nb\nc"))
        _ = try ReviewPrompt(validating: "a\nb\nc")
    }

    /// An escape a client writes would reach the program as keys. The paste
    /// refuses it, so it is dropped rather than typed.
    @Test func anEscape_isNotTextAPasteCarries() {
        #expect(throws: ReviewError.self) { try ReviewPrompt(validating: "\u{1B}[A") }
    }

    /// The whole-value setter is refused, so a client that cannot insert
    /// learns that instead of getting a success that typed nothing; an insert
    /// at the caret is what the pane takes.
    @Test func aClientMayWriteAtTheCaret_butNotReplaceTheScreen() throws {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let view = SurfaceView(ghosttyApp: ghosttyApp, makeSurface: { _, _ in nil })
        #expect(view.accessibilityRole() == .textArea)
        #expect(view.isAccessibilitySelectorAllowed(#selector(NSView.setAccessibilitySelectedText(_:))))
        #expect(!view.isAccessibilitySelectorAllowed(#selector(NSView.setAccessibilityValue(_:))))
    }

    // MARK: - Into a terminal

    /// A pane running `cat` behind bracketed paste: `cat`'s terminal echoes
    /// what it receives, and a paste shows its framing (`^[[200~`) where a
    /// typed line shows none.
    private func mountedCat() throws -> (window: NSWindow, view: SurfaceView) {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let view = SurfaceView(ghosttyApp: ghosttyApp) { app, config in
            var config = config
            return #"/bin/sh -c "printf '\033[?2004hcat-ready\n'; exec cat""#.withCString { command in
                config.command = command
                return SurfaceView.newGhosttySurface(app: app, config: config)
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return (window, view)
    }

    /// A pane whose shell has asked for bracketed paste, found by the marker
    /// the shell prints right after the request. Text typed before then is
    /// echoed by the terminal as well, so seeing it proves nothing.
    private func readyCat() async throws -> (window: NSWindow, view: SurfaceView) {
        let mounted = try mountedCat()
        #expect(await screen(of: mounted.view, shows: "cat-ready"))
        return mounted
    }

    private func screen(of view: SurfaceView, shows text: String) async -> Bool {
        await pollUntil(timeout: .seconds(10), interval: .milliseconds(50)) {
            view.activeScreenText()?.contains(text) == true
        }
        return view.activeScreenText()?.contains(text) == true
    }

    @Test(.tags(.ffi), .timeLimit(.minutes(1)), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func aLineAClientWrites_reachesTheTerminalAsTyped() async throws {
        let (window, view) = try await readyCat()
        defer { window.close() }
        #expect(view.surface != nil)

        view.setAccessibilitySelectedText("typed-by-a-client")

        #expect(await screen(of: view, shows: "typed-by-a-client"))
        #expect(view.lastKeyInputAt != nil, "the draft was not marked as typed")
        #expect(view.activeScreenText()?.contains("200~") == false)
        // The value a client reads back is the screen, so it sees the write.
        #expect((view.accessibilityValue() as? String)?.contains("typed-by-a-client") == true)
    }

    /// `cat` prints a line back once Return ends it, so the line shows twice.
    @Test(.tags(.ffi), .timeLimit(.minutes(1)), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func aLineBreakAClientWrites_sendsTheLine() async throws {
        let (window, view) = try await readyCat()
        defer { window.close() }
        view.setAccessibilitySelectedText("sent-line")
        #expect(await screen(of: view, shows: "sent-line"))

        view.setAccessibilitySelectedText("\n")

        await pollUntil(timeout: .seconds(10), interval: .milliseconds(50)) {
            (view.activeScreenText()?.components(separatedBy: "sent-line").count ?? 0) > 2
        }
        #expect(view.activeScreenText()?.components(separatedBy: "sent-line").count == 3)
        #expect(!view.hasUnsubmittedInput)
    }

    /// A Return pressed while a composition is open sends the composed text
    /// with the line, not the line without it.
    @Test(.tags(.ffi), .timeLimit(.minutes(1)), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func aLineBreakDuringAComposition_commitsTheComposedTextFirst() async throws {
        let (window, view) = try await readyCat()
        defer { window.close() }
        view.setAccessibilitySelectedText("before-")
        #expect(await screen(of: view, shows: "before-"))
        view.setMarkedText(
            "composed",
            selectedRange: NSRange(location: 8, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        view.setAccessibilitySelectedText("\n")

        #expect(!view.hasMarkedText())
        await pollUntil(timeout: .seconds(10), interval: .milliseconds(50)) {
            (view.activeScreenText()?.components(separatedBy: "before-composed").count ?? 0) > 2
        }
        #expect(view.activeScreenText()?.components(separatedBy: "before-composed").count == 3)
    }

    /// A line a client writes during a composition follows the composed text
    /// rather than replacing it.
    @Test(.tags(.ffi), .timeLimit(.minutes(1)), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func aLineDuringAComposition_followsTheComposedText() async throws {
        let (window, view) = try await readyCat()
        defer { window.close() }
        view.setMarkedText(
            "composed",
            selectedRange: NSRange(location: 8, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        view.setAccessibilitySelectedText("-then-typed")

        #expect(!view.hasMarkedText())
        #expect(await screen(of: view, shows: "composed-then-typed"))
    }

    @Test(.tags(.ffi), .timeLimit(.minutes(1)), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func linesAClientWrites_reachTheTerminalAsOnePaste() async throws {
        let (window, view) = try await readyCat()
        defer { window.close() }
        view.setAccessibilitySelectedText("first-line\nsecond-line")

        #expect(await screen(of: view, shows: "second-line"))
        #expect(view.activeScreenText()?.contains("[200~first-line") == true)
        #expect(view.takeStagedPaste() == nil)
    }
}
