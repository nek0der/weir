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
            recordID: String = ""
        ) {
            store.receive(
                ProgramStatusReport(app: app, recordID: recordID, state: state, kind: kind),
                in: PaneProgramStatusStoreTests.pane
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
                observedAt: AgentDateParsing.formatISO8601(Self.at),
                stateSince: AgentDateParsing.formatISO8601(Self.at)
            )
        ])
        #expect(scene.changes == 1)

        // The same state again changes nothing the projection reads.
        scene.report(.blocked)
        #expect(scene.changes == 1)
        scene.report(.idle)
        #expect(scene.store.statuses[Self.pane]?.state == .idle)
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
        scene.report(.working, kind: .question)
        #expect(scene.store.statuses[Self.pane]?.kind == nil)
        #expect(scene.store.projectionInput[Self.pane.uuidString]?.kind == nil)
    }

    /// An `auth` that repeats has stood since its first report, or one sent
    /// every second would never become a wait.
    @Test func aRepeatedReport_keepsWhenTheStateBegan() {
        var clock = Self.at
        let store = PaneProgramStatusStore(now: { clock })
        let auth = ProgramStatusReport(app: "antigravity", recordID: "", state: .blocked, kind: .auth)
        store.receive(auth, in: Self.pane)
        clock = Self.at.addingTimeInterval(3)
        store.receive(auth, in: Self.pane)
        #expect(store.statuses[Self.pane]?.observedAt == clock)
        #expect(store.statuses[Self.pane]?.stateSince == Self.at)

        clock = Self.at.addingTimeInterval(4)
        store.receive(
            ProgramStatusReport(app: "antigravity", recordID: "", state: .blocked, kind: .permission),
            in: Self.pane
        )
        #expect(store.statuses[Self.pane]?.stateSince == clock, "another kind is another wait")
    }

    @Test func aReportAboutPartOfTheWork_isNotKept() {
        let scene = Scene()
        scene.report(.working, recordID: "deploy/us-east")
        #expect(scene.store.statuses.isEmpty)
        #expect(scene.changes == 0)
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

    @Test func whileAnAgentReports_everyTitleIsLeftOff() {
        let scene = Scene()
        #expect(!scene.store.silencesTitle("~/dev/project", from: Self.pane), "no report, no change")
        scene.report(.idle)
        #expect(scene.store.silencesTitle("Claude Code", from: Self.pane))
        #expect(scene.store.silencesTitle("", from: Self.pane))
    }

    @Test func anotherProgramsTitles_areLetThrough() {
        let scene = Scene()
        scene.report(.working, app: "cargo")
        #expect(!scene.store.silencesTitle("cargo build", from: Self.pane))
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
        scene.report(.blocked)
        scene.store.forget(Self.pane)
        #expect(scene.store.statuses.isEmpty)
        #expect(!scene.store.silencesTitle("", from: Self.pane))
        #expect(scene.changes == 2)
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

    @Test func aClosedPane_isNoLongerBackAtTheShell() {
        let scene = Scene()
        scene.store.commandReturnedToShell(in: Self.pane)
        scene.store.forget(Self.pane)
        #expect(scene.store.panesBackAtShell.isEmpty)
    }
}
