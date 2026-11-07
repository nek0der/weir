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
    private enum TapStep: Equatable {
        case activated
        case tapped(UUID?)
        case completed
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

    /// Calls the nonisolated delegate entry from a detached task and waits
    /// for the completion delivered by its hop.
    private func present(_ userInfo: [AnyHashable: Any]) async -> [UNNotificationPresentationOptions] {
        let delegate = WeirNotificationDelegate(activateApp: {})
        let facts = NotificationPresentationFacts(userInfo: userInfo)
        let calls = Recorded<[UNNotificationPresentationOptions]>([])
        await Task.detached {
            delegate.present(facts) { options in
                calls.update { $0.append(options) }
            }
        }.value
        await pollUntil { !calls.value.isEmpty }
        return calls.value
    }

    @Test(arguments: [false, true])
    func present_offTheMainActor_followsSourceVisibility(isSeen: Bool) async {
        await withHooks {
            let pane = UUID()
            var asked: [(UUID?, String?)] = []
            WeirNotificationDelegate.isSourceSeen = { paneID, runtimeID in
                asked.append((paneID, runtimeID))
                return isSeen
            }
            let options = await present(Self.agentUserInfo(paneID: pane))
            let expected: UNNotificationPresentationOptions = isSeen ? [] : [.banner, .sound]
            #expect(options == [expected])
            #expect(asked.map(\.0) == [pane])
            #expect(asked.map(\.1) == ["runtime-1"])
        }
    }

    @Test func present_aBannerThatAsksNoFocus_showsEvenWhileTheSourceIsSeen() async {
        await withHooks {
            WeirNotificationDelegate.isSourceSeen = { _, _ in true }
            let options = await present(Self.agentUserInfo(paneID: UUID(), requireFocus: false))
            #expect(options == [[.banner, .sound]])
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

            let unfocused = await present(Self.commandUserInfo(paneID: pane))
            #expect(unfocused == [[.banner, .sound]])

            surface.holdsKeyboardFocus = true
            let focused = await present(Self.commandUserInfo(paneID: pane))
            #expect(focused == [[]])
        }
    }

    /// A banner that arrives before the registry is wired shows: a banner
    /// we need not have shown is recoverable, a lost one is not.
    @Test func present_withoutARegistry_offersBannerAndSound() async {
        await withHooks {
            WeirNotificationDelegate.registry = nil
            let options = await present(Self.commandUserInfo(paneID: UUID()))
            #expect(options == [[.banner, .sound]])
        }
    }

    /// A tap that launched the app arrives before the attention list is
    /// up. The handler is looked up on the main actor after the hop, so
    /// one installed before the hop runs still gets the tap.
    @Test func deliverTap_aHandlerInstalledBeforeTheHopRuns_getsTheTap() async {
        await withHooks {
            WeirNotificationDelegate.onTap = nil
            let trace = Recorded<[TapStep]>([])
            let delegate = WeirNotificationDelegate(activateApp: { trace.update { $0.append(.activated) } })
            let pane = UUID()
            let payload = NotificationTapPayload(userInfo: [NotificationPayloadKey.paneID: pane.uuidString])
            // Still on the main actor, so the hop cannot run until we yield.
            delegate.deliverTap(payload) {
                trace.update { $0.append(.completed) }
            }
            #expect(trace.value.isEmpty)
            WeirNotificationDelegate.onTap = { payload in trace.update { $0.append(.tapped(payload.paneID)) } }
            await pollUntil { trace.value.contains(.completed) }
            #expect(trace.value == [.activated, .tapped(pane), .completed])
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
