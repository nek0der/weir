// SurfaceInputDispatchTests.swift
// Weir — a key the input context turns into a command reaches libghostty once, and each extra mouse button keeps its own name.

import AppKit
import Carbon.HIToolbox
import GhosttyKit
import Testing
@testable import Weir

@MainActor
struct SurfaceInputDispatchTests {

    // MARK: - A key sent by doCommand

    @Test func uncommittedKey_sentByCommand_isNotSentAgain() {
        for hasKeybindModifiers in [true, false] {
            for isConsumed in [true, false] {
                #expect(!SurfaceView.forwardsUncommittedKey(
                    isComposing: false,
                    isConsumed: isConsumed,
                    hasKeybindModifiers: hasKeybindModifiers,
                    wasForwardedByCommand: true
                ))
            }
        }
    }

    @Test func uncommittedKey_notSentByCommand_keepsTheEarlierRule() {
        // A key the input context left alone goes on, and so does a
        // consumed one held with ⌘, ⌃, or ⌥.
        #expect(SurfaceView.forwardsUncommittedKey(
            isComposing: false, isConsumed: false, hasKeybindModifiers: false, wasForwardedByCommand: false
        ))
        #expect(SurfaceView.forwardsUncommittedKey(
            isComposing: false, isConsumed: true, hasKeybindModifiers: true, wasForwardedByCommand: false
        ))
        // A plain key the input context consumed stays dropped.
        #expect(!SurfaceView.forwardsUncommittedKey(
            isComposing: false, isConsumed: true, hasKeybindModifiers: false, wasForwardedByCommand: false
        ))
        // During composition the key belongs to the input method.
        #expect(!SurfaceView.forwardsUncommittedKey(
            isComposing: true, isConsumed: false, hasKeybindModifiers: true, wasForwardedByCommand: false
        ))
    }

    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func doCommand_marksTheKeyBeingDispatchedAsSent() throws {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let surface = PaneHostRepresentable.makeSurfaceView(ghosttyApp: ghosttyApp, environment: [:])
        let optionDelete = try NSEvent.testKeyDown(
            keyCode: UInt16(kVK_Delete),
            modifiers: .option,
            characters: "\u{7F}"
        )
        surface.activeKeyEvent = optionDelete
        defer { surface.activeKeyEvent = nil }
        #expect(!surface.hasForwardedActiveKeyEvent)

        surface.doCommand(by: #selector(NSResponder.deleteWordBackward(_:)))

        #expect(surface.hasForwardedActiveKeyEvent)
    }

    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func doCommand_outsideAKeyDispatch_marksNothing() throws {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let surface = PaneHostRepresentable.makeSurfaceView(ghosttyApp: ghosttyApp, environment: [:])

        surface.doCommand(by: #selector(NSResponder.deleteWordBackward(_:)))

        #expect(!surface.hasForwardedActiveKeyEvent)
    }

    /// The mark lasts one dispatch: a key `doCommand:` sent must not keep
    /// the next key, which no command takes, from reaching the terminal.
    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func keyDown_clearsTheMarkForTheNextKey() throws {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let view = SurfaceView(ghosttyApp: ghosttyApp)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        _ = try #require(view.surface, "the mount never created the surface")
        let optionDelete = try NSEvent.testKeyDown(
            keyCode: UInt16(kVK_Delete),
            modifiers: .option,
            characters: "\u{7F}"
        )

        view.activeKeyEvent = optionDelete
        view.doCommand(by: #selector(NSResponder.deleteWordBackward(_:)))
        try #require(view.hasForwardedActiveKeyEvent)

        let next = try NSEvent.testKeyDown(keyCode: UInt16(kVK_ANSI_A), characters: "a")
        view.keyDown(with: next)

        #expect(!view.hasForwardedActiveKeyEvent)
        #expect(view.activeKeyEvent == nil)
    }

    // MARK: - Extra mouse buttons

    @Test func otherMouseButton_namesEachButtonAsGhosttyDoes() {
        let expected: [(Int, ghostty_input_mouse_button_e)] = [
            (2, GHOSTTY_MOUSE_MIDDLE),
            (3, GHOSTTY_MOUSE_EIGHT),
            (4, GHOSTTY_MOUSE_NINE),
            (5, GHOSTTY_MOUSE_SIX),
            (6, GHOSTTY_MOUSE_SEVEN),
            (7, GHOSTTY_MOUSE_FOUR),
            (8, GHOSTTY_MOUSE_FIVE),
            (9, GHOSTTY_MOUSE_TEN),
            (10, GHOSTTY_MOUSE_ELEVEN)
        ]
        for (number, button) in expected {
            #expect(SurfaceView.otherMouseButton(number) == button, "button \(number)")
        }
    }

    @Test func otherMouseButton_withNoName_isDropped() {
        #expect(SurfaceView.otherMouseButton(11) == nil)
        #expect(SurfaceView.otherMouseButton(31) == nil)
    }
}
