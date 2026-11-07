// PaneProgramStatusStoreTests.swift
// Weir — which OSC 7501 reports a pane keeps, and which titles they leave off its tab.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("Pane program status")
struct PaneProgramStatusStoreTests {
    private static let pane = UUID(uuidString: "11111111-1111-4111-8111-111111111111") ?? UUID()
    private static let at = Date(timeIntervalSince1970: 1_800_000_000)

    /// A store that knows Claude Code as an agent and counts its changes.
    @MainActor
    private final class Scene {
        let store = PaneProgramStatusStore(now: { PaneProgramStatusStoreTests.at })
        var changes = 0

        init() {
            store.agentApps = ["claude-code"]
            store.onChange = { [unowned self] in changes += 1 }
        }

        func report(
            _ state: ProgramStatusReport.State,
            kind: ProgramStatusReport.Kind? = nil,
            app: String = "claude-code",
            recordID: String = "",
            pane: UUID = PaneProgramStatusStoreTests.pane
        ) {
            store.receive(
                ProgramStatusReport(app: app, recordID: recordID, state: state, kind: kind),
                in: pane
            )
        }
    }

    @Test func aReport_isWhatTheProjectionReads() {
        let scene = Scene()
        scene.report(.blocked)
        #expect(scene.store.projectionInput == [
            Self.pane.uuidString: AgentProjectionProgramStatus(
                app: "claude-code",
                state: "blocked",
                observedAt: "2027-01-15T08:00:00Z",
                stateSince: "2027-01-15T08:00:00Z"
            )
        ])
        #expect(scene.changes == 1)

        // The same state again changes nothing the projection reads.
        scene.report(.blocked)
        #expect(scene.changes == 1)
        scene.report(.idle)
        #expect(scene.store.statuses[Self.pane]?.state == .idle)
        #expect(scene.store.projectionInput == [
            Self.pane.uuidString: AgentProjectionProgramStatus(
                app: "claude-code",
                state: "idle",
                observedAt: "2027-01-15T08:00:00Z",
                stateSince: "2027-01-15T08:00:00Z"
            )
        ])
        #expect(scene.changes == 2)
    }

    @Test func aBlocksKind_isWhatTheProjectionReads_andAnotherKindRequestsAPass() {
        let scene = Scene()
        scene.report(.blocked, kind: .question)
        #expect(scene.store.projectionInput[Self.pane.uuidString]?.kind == "question")
        #expect(scene.changes == 1)

        scene.report(.blocked, kind: .auth)
        #expect(scene.store.projectionInput[Self.pane.uuidString]?.kind == "auth")
        #expect(scene.changes == 2)
    }

    /// The protocol sends a kind only with a block; one on any other state
    /// says nothing the rules read.
    @Test func aKindOnAnotherState_isNotKept() {
        let scene = Scene()
        scene.report(.blocked, kind: .question)
        #expect(scene.store.projectionInput[Self.pane.uuidString]?.kind == "question")
        scene.report(.working, kind: .question)
        #expect(scene.store.statuses[Self.pane]?.state == .working)
        #expect(scene.store.projectionInput[Self.pane.uuidString]?.state == "working")
        #expect(scene.store.statuses[Self.pane]?.kind == nil)
        #expect(scene.store.projectionInput[Self.pane.uuidString]?.kind == nil)
    }

    /// An `auth` that repeats has stood since its first report, or one sent
    /// every second would never become a wait.
    @Test func aRepeatedReport_keepsWhenTheStateBegan() {
        var clock = Self.at
        let store = PaneProgramStatusStore(now: { clock })
        store.agentApps = ["antigravity"]
        var changes = 0
        store.onChange = { changes += 1 }
        let auth = ProgramStatusReport(app: "antigravity", recordID: "", state: .blocked, kind: .auth)
        store.receive(auth, in: Self.pane)
        #expect(changes == 1)
        clock = Self.at.addingTimeInterval(3)
        store.receive(auth, in: Self.pane)
        #expect(store.statuses[Self.pane]?.observedAt == clock)
        #expect(store.statuses[Self.pane]?.stateSince == Self.at)
        #expect(store.projectionInput[Self.pane.uuidString] == AgentProjectionProgramStatus(
            app: "antigravity", state: "blocked", kind: "auth",
            observedAt: "2027-01-15T08:00:03Z", stateSince: "2027-01-15T08:00:00Z"
        ))
        #expect(changes == 1)

        clock = Self.at.addingTimeInterval(4)
        store.receive(
            ProgramStatusReport(app: "antigravity", recordID: "", state: .blocked, kind: .permission),
            in: Self.pane
        )
        #expect(store.statuses[Self.pane]?.stateSince == clock, "another kind is another wait")
        #expect(store.projectionInput[Self.pane.uuidString] == AgentProjectionProgramStatus(
            app: "antigravity", state: "blocked", kind: "permission",
            observedAt: "2027-01-15T08:00:04Z", stateSince: "2027-01-15T08:00:04Z"
        ))
        #expect(changes == 2)
    }

    @Test func aReportAboutPartOfTheWork_isNotKept() {
        let scene = Scene()
        scene.report(.working, recordID: "deploy/us-east")
        #expect(scene.store.statuses.isEmpty)
        #expect(scene.changes == 0)

        scene.report(.blocked, kind: .auth)
        let root = scene.store.statuses
        let projection = scene.store.projectionInput
        #expect(root[Self.pane]?.state == .blocked)
        scene.report(.working, recordID: "deploy/us-east")
        scene.report(.clear, recordID: "deploy/us-east")
        #expect(scene.store.statuses == root)
        #expect(scene.store.projectionInput == projection)
        #expect(scene.changes == 1)
    }

    @Test func clear_removesThePanesStatus() {
        let scene = Scene()
        scene.report(.idle)
        scene.report(.clear)
        #expect(scene.store.statuses.isEmpty)
        #expect(scene.store.projectionInput.isEmpty)
        #expect(scene.changes == 2)
    }

    @Test func anotherProgramsReport_isKept_butRequestsNoPass() {
        let scene = Scene()
        scene.report(.working, app: "cargo")
        #expect(scene.store.statuses[Self.pane]?.app == "cargo")
        #expect(scene.changes == 0)
    }

    @Test(arguments: [
        (nil as String?, "~/dev/project", false),
        ("claude-code", "Claude Code", true),
        ("claude-code", "", true),
        ("cargo", "cargo build", false),
        ("cargo", "", false)
    ])
    func titlesAreSuppressedOnlyForAnActiveAgentReport(app: String?, title: String, suppressed: Bool) {
        let scene = Scene()
        if let app {
            scene.report(.idle, app: app)
            #expect(scene.store.statuses[Self.pane]?.app == app)
        }
        #expect(scene.store.silencesTitle(title, from: Self.pane) == suppressed)
    }

    @Test func afterTheAgentClears_onlyItsEmptyExitTitleIsLeftOff() {
        let scene = Scene()
        scene.report(.idle)
        scene.report(.clear)
        // Claude Code clears its title on its way out.
        #expect(scene.store.silencesTitle("", from: Self.pane))
        // The shell's next title is let through, and the one after that too.
        #expect(!scene.store.silencesTitle("~/dev/project", from: Self.pane))
        #expect(!scene.store.silencesTitle("", from: Self.pane))
    }

    @Test func aPaneWhoseProgramIsGone_isForgotten() {
        let scene = Scene()
        let other = UUID()
        scene.store.commandReturnedToShell(in: Self.pane)
        scene.store.commandReturnedToShell(in: other)
        scene.report(.blocked)
        scene.report(.idle, pane: other)
        let peer = scene.store.statuses[other]
        #expect(scene.store.panesBackAtShell == [Self.pane, other])
        #expect(scene.store.statuses[Self.pane]?.state == .blocked)
        #expect(peer?.state == .idle)
        let changes = scene.changes

        scene.store.forget(Self.pane)

        #expect(scene.store.statuses[Self.pane] == nil)
        #expect(scene.store.statuses[other] == peer)
        #expect(scene.store.panesBackAtShell == [other])
        #expect(!scene.store.silencesTitle("", from: Self.pane))
        #expect(scene.store.silencesTitle("", from: other))
        #expect(scene.changes == changes + 1)
    }

    @Test(arguments: [false, true])
    func aReturnToTheShellEndsTheReportAndPublishesTheShellMarker(hasReport: Bool) {
        let scene = Scene()
        var shellSnapshots: [Set<UUID>] = []
        var statusSnapshots: [[UUID: PaneProgramStatusStore.Status]] = []
        scene.store.onChange = {
            shellSnapshots.append(scene.store.panesBackAtShell)
            statusSnapshots.append(scene.store.statuses)
        }
        defer { scene.store.onChange = nil }
        if hasReport {
            scene.report(.blocked)
            #expect(statusSnapshots.last?[Self.pane]?.state == .blocked)
            #expect(shellSnapshots.last == [])
        }

        let beforeReturn = shellSnapshots.count
        scene.store.commandReturnedToShell(in: Self.pane)
        #expect(shellSnapshots.count == beforeReturn + 1)
        #expect(shellSnapshots.last == [Self.pane])
        #expect(statusSnapshots.last == [:])
        #expect(scene.store.panesBackAtShell == [Self.pane])
        let count = shellSnapshots.count

        scene.store.commandReturnedToShell(in: Self.pane)
        #expect(shellSnapshots.count == count)

        scene.report(.idle)
        #expect(statusSnapshots.last?[Self.pane]?.state == .idle)
        scene.store.commandReturnedToShell(in: Self.pane)
        #expect(scene.store.statuses.isEmpty)
        #expect(scene.store.panesBackAtShell == [Self.pane])
        #expect(shellSnapshots.count == count + 2)
        #expect(shellSnapshots.last == [Self.pane], "the pass must read the completed shell return")
        #expect(statusSnapshots.last == [:])
    }
}
