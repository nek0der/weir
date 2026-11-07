// SurfaceAccessibilityTextTests.swift
// Weir — text an accessibility client writes into a pane reaches the terminal, and several lines arrive as a paste.

import AppKit
import GhosttyKit
import Testing
@testable import Weir

@Suite("Surface accessibility text")
@MainActor
struct SurfaceAccessibilityTextTests {

    @Test(arguments: [
        ("echo hello" as String?, AccessibilityTextRoute.typed("echo hello") as AccessibilityTextRoute?),
        ("日本語のプロンプト", .typed("日本語のプロンプト")),
        (nil, nil),
        ("", nil),
        ("echo a\necho b", .pasted("echo a\necho b")),
        ("echo a\n", .pasted("echo a\n")),
        ("\t", .pasted("\t")),
        ("\u{1B}[A", .pasted("\u{1B}[A")),
        ("\n", .returnKey),
        ("\r", .returnKey),
        ("\r\n", .returnKey),
        ("a\r\nb\rc", .pasted("a\nb\nc"))
    ])
    func accessibilityTextChoosesTheExactInputRoute(text: String?, expected: AccessibilityTextRoute?) throws {
        let route = AccessibilityTextRoute(text)
        #expect(route == expected)
        if text == "\u{1B}[A" {
            #expect(throws: ReviewError.invalidText) { try ReviewPrompt(validating: "\u{1B}[A") }
        }
        if text == "a\r\nb\rc", case let .pasted(payload) = try #require(route) {
            _ = try ReviewPrompt(validating: payload)
        }
    }

    /// An escape would reach the program as keys if typed. AX must drop
    /// the rejected paste, while still accepting a later ordinary write.
    @Test(.tags(.ffi), .timeLimit(.minutes(1)), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func anEscape_isNotTextAPasteCarries() async throws {
        let rejected = "\u{1B}[Aax-escape-rejected"
        #expect(throws: ReviewError.invalidText) { try ReviewPrompt(validating: rejected) }
        let (window, view) = try await readyCat()
        defer { window.close() }
        try #require(view.surface != nil)
        #expect(!view.hasUnsubmittedInput)
        let lastInput = view.lastKeyInputAt

        view.setAccessibilitySelectedText(rejected)

        #expect(!view.hasUnsubmittedInput)
        #expect(view.lastKeyInputAt == lastInput)
        #expect(view.takeStagedPaste() == nil)
        view.setAccessibilitySelectedText("ax-typed-after-refusal")
        try #require(await screen(of: view, shows: "ax-typed-after-refusal"))
        let output = try #require(view.activeScreenText())
        #expect(!output.contains("ax-escape-rejected"))
        #expect(!output.contains("[200~"))
        #expect(view.hasUnsubmittedInput)
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

    /// Mounts a real Ghostty surface running the fixture command in its own window.
    private func mountedTerminal(_ command: String) throws -> (window: NSWindow, view: SurfaceView) {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let view = SurfaceView(ghosttyApp: ghosttyApp) { app, config in
            var config = config
            return command.withCString { command in
                config.command = command
                return SurfaceView.newGhosttySurface(app: app, config: config)
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return (window, view)
    }

    /// Waits for the shell to enable bracketed paste before handing input to
    /// `cat`. The terminal echoes each line, then `cat` repeats it once submitted.
    private func readyCat() async throws -> (window: NSWindow, view: SurfaceView) {
        let mounted = try mountedTerminal(#"/bin/sh -c "printf '\033[?2004hcat-ready\n'; exec cat""#)
        do {
            try #require(await screen(of: mounted.view, shows: "cat-ready"))
            return mounted
        } catch {
            mounted.window.close()
            throw error
        }
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

        try #require(view.hasMarkedText())
        view.setAccessibilitySelectedText("\n")

        #expect(!view.hasMarkedText())
        await pollUntil(timeout: .seconds(10), interval: .milliseconds(50)) {
            (view.activeScreenText()?.components(separatedBy: "before-composed").count ?? 0) > 2
        }
        #expect(view.activeScreenText()?.components(separatedBy: "before-composed").count == 3)
        #expect(!view.hasUnsubmittedInput)
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

        try #require(view.hasMarkedText())
        view.setAccessibilitySelectedText("-then-typed")

        #expect(!view.hasMarkedText())
        try #require(await screen(of: view, shows: "composed-then-typed"))
        #expect(view.activeScreenText()?.components(separatedBy: "composed-then-typed").count == 2)
        #expect(view.hasUnsubmittedInput)

        view.setAccessibilitySelectedText("\r\n")

        await pollUntil(timeout: .seconds(10), interval: .milliseconds(50)) {
            view.activeScreenText()?.components(separatedBy: "composed-then-typed").count == 3
        }
        #expect(view.activeScreenText()?.components(separatedBy: "composed-then-typed").count == 3)
        #expect(!view.hasUnsubmittedInput)
    }

    @Test(.tags(.ffi), .timeLimit(.minutes(1)), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func linesAClientWrites_reachTheTerminalAsOnePaste() async throws {
        let text = "first-line\nsecond-line"
        let expected = "\u{1B}[200~\(text)\u{1B}[201~".utf8.map { String(format: "%02x", $0) }.joined()
        // Read raw PTY bytes rather than relying on terminal echo to make
        // both escape sequences visible. The second read detects any byte
        // inserted between the end of the frame and the typed sentinel.
        let script = [
            "/bin/stty raw -echo opost onlcr",
            #"printf '\033[?2004hax-raw-ready\n'"#,
            "/bin/dd bs=1 count=\(expected.count / 2) 2>/dev/null | /usr/bin/od -An -v -tx1",
            #"printf 'ax-frame-seen\n'"#,
            "/bin/dd bs=1 count=1 2>/dev/null | /usr/bin/od -An -v -tx1",
            #"printf 'ax-tail-seen\n'"#,
            "exec /bin/cat"
        ].joined(separator: "; ")
        let (window, view) = try mountedTerminal("/bin/sh -c \"\(script)\"")
        defer { window.close() }
        try #require(await screen(of: view, shows: "ax-raw-ready"))

        view.setAccessibilitySelectedText(text)

        try #require(await screen(of: view, shows: "ax-frame-seen"), "received \(view.activeScreenText() ?? "")")
        view.setAccessibilitySelectedText("!")
        try #require(await screen(of: view, shows: "ax-tail-seen"))
        let output = try #require(view.activeScreenText())
        let sections = output.components(separatedBy: "ax-frame-seen")
        try #require(sections.count == 2)
        let frame = try #require(sections[0].components(separatedBy: "ax-raw-ready").last)
        let tail = try #require(sections[1].components(separatedBy: "ax-tail-seen").first)
        #expect(frame.filter { !$0.isWhitespace } == expected)
        #expect(tail.filter { !$0.isWhitespace } == "21")
        #expect(view.takeStagedPaste() == nil)
    }
}
