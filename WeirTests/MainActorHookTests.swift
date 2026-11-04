// MainActorHookTests.swift
// Weir — the static hooks the main actor owns are read there, after an AppKit or UN callback's hop.

import AppKit
import Foundation
import Testing
import UserNotifications
@testable import Weir
@testable import WeirDomain

/// Each test sets the hooks it reads and puts them back before it returns.
/// The suite runs serialized on the main actor, and the test host never
/// creates an `AppState`, so nothing else installs these hooks meanwhile.
@MainActor
@Suite("Main-actor static hooks", .serialized, .timeLimit(.minutes(1)))
struct MainActorHookTests {
    /// What a completion handler called from the main actor's hop saw.
    @MainActor
    private final class Calls {
        var options: [UNNotificationPresentationOptions] = []
        var completions = 0
        var activations = 0
        var taps: [NotificationTapPayload] = []
    }

    private func withHooks(_ body: () async throws -> Void) async rethrows {
        let previous = (
            WeirNotificationDelegate.registry,
            WeirNotificationDelegate.onTap,
            WeirNotificationDelegate.isSourceSeen
        )
        defer {
            WeirNotificationDelegate.registry = previous.0
            WeirNotificationDelegate.onTap = previous.1
            WeirNotificationDelegate.isSourceSeen = previous.2
        }
        try await body()
    }

    /// The `userInfo` an agent's banner carries.
    private static func agentUserInfo(paneID: UUID, requireFocus: Bool = true) -> [AnyHashable: Any] {
        [
            NotificationPayloadKey.kind: NotificationEntry.Kind.agentFinished.rawValue,
            NotificationPayloadKey.paneID: paneID.uuidString,
            NotificationPayloadKey.runtimeID: "runtime-1",
            NotificationPayloadKey.requireFocus: requireFocus
        ]
    }

    /// Calls `present` from a thread off the main actor, as a UN callback
    /// on a system queue does, and waits for the hop to answer.
    private func present(_ userInfo: [AnyHashable: Any], calls: Calls) async {
        let delegate = WeirNotificationDelegate(activateApp: {})
        let facts = NotificationPresentationFacts(userInfo: userInfo)
        await Task.detached {
            delegate.present(facts) { options in
                Task { @MainActor in calls.options.append(options) }
            }
        }.value
        await pollUntil { !calls.options.isEmpty }
    }

    @Test func present_offTheMainActor_hidesTheBannerWhileTheSourceIsSeen() async {
        await withHooks {
            let pane = UUID()
            var asked: [(UUID?, String?)] = []
            WeirNotificationDelegate.isSourceSeen = { paneID, runtimeID in
                asked.append((paneID, runtimeID))
                return true
            }
            let calls = Calls()
            await present(Self.agentUserInfo(paneID: pane), calls: calls)
            #expect(calls.options == [[]])
            #expect(asked.map(\.0) == [pane])
            #expect(asked.map(\.1) == ["runtime-1"])
        }
    }

    @Test func present_offTheMainActor_showsTheBannerWhileTheSourceIsNotSeen() async {
        await withHooks {
            WeirNotificationDelegate.isSourceSeen = { _, _ in false }
            let calls = Calls()
            await present(Self.agentUserInfo(paneID: UUID()), calls: calls)
            #expect(calls.options == [[.banner, .sound]])
        }
    }

    @Test func present_aBannerThatAsksNoFocus_showsEvenWhileTheSourceIsSeen() async {
        await withHooks {
            WeirNotificationDelegate.isSourceSeen = { _, _ in true }
            let calls = Calls()
            await present(Self.agentUserInfo(paneID: UUID(), requireFocus: false), calls: calls)
            #expect(calls.options == [[.banner, .sound]])
        }
    }

    /// The `userInfo` a command's banner carries: no agent, so the pane's
    /// keyboard focus decides, read through `registry`.
    private static func commandUserInfo(paneID: UUID) -> [AnyHashable: Any] {
        [
            NotificationPayloadKey.kind: NotificationEntry.Kind.commandFinished.rawValue,
            NotificationPayloadKey.paneID: paneID.uuidString
        ]
    }

    @Test func present_aCommandsBanner_followsThePanesKeyboardFocus() async {
        await withHooks {
            let pane = UUID()
            let surface = RecordingPaneSurface()
            let registry = RecordingSurfaceRegistry()
            registry.surfaces[pane] = surface
            WeirNotificationDelegate.registry = registry
            // A source an agent's hook would call seen must not decide here.
            WeirNotificationDelegate.isSourceSeen = { _, _ in true }

            let unfocused = Calls()
            await present(Self.commandUserInfo(paneID: pane), calls: unfocused)
            #expect(unfocused.options == [[.banner, .sound]])

            surface.holdsKeyboardFocus = true
            let focused = Calls()
            await present(Self.commandUserInfo(paneID: pane), calls: focused)
            #expect(focused.options == [[]])
        }
    }

    /// A banner that arrives before the registry is wired shows: a banner
    /// we need not have shown is recoverable, a lost one is not.
    @Test func present_withNoRegistry_failsClosedToABanner() async {
        await withHooks {
            WeirNotificationDelegate.registry = nil
            let calls = Calls()
            await present(Self.commandUserInfo(paneID: UUID()), calls: calls)
            #expect(calls.options == [[.banner, .sound]])
        }
    }

    /// A tap that launched the app arrives before the attention list is
    /// up. The handler is looked up on the main actor after the hop, so
    /// one installed before the hop runs still gets the tap.
    @Test func deliverTap_aHandlerInstalledBeforeTheHopRuns_getsTheTap() async {
        await withHooks {
            WeirNotificationDelegate.onTap = nil
            let calls = Calls()
            let delegate = WeirNotificationDelegate(activateApp: { calls.activations += 1 })
            let pane = UUID()
            let payload = NotificationTapPayload(userInfo: [NotificationPayloadKey.paneID: pane.uuidString])
            // Still on the main actor, so the hop cannot run until we yield.
            delegate.deliverTap(payload) {
                Task { @MainActor in calls.completions += 1 }
            }
            WeirNotificationDelegate.onTap = { calls.taps.append($0) }
            await pollUntil { calls.completions > 0 }
            #expect(calls.taps.map(\.paneID) == [pane])
            #expect(calls.activations == 1)
            #expect(calls.completions == 1)
        }
    }

    @Test func applicationShouldTerminate_followsTheQuitGate() {
        let previous = WeirAppDelegate.quitGate
        defer { WeirAppDelegate.quitGate = previous }
        let delegate = WeirAppDelegate()
        WeirAppDelegate.quitGate = { false }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        WeirAppDelegate.quitGate = { true }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        WeirAppDelegate.quitGate = nil
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }
}
