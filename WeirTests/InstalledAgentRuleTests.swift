// InstalledAgentRuleTests.swift
// Weir — which agents the "+" menu and the plan usage panel name, the note under the menu, and the store they read.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct InstalledAgentRuleTests {
    private let catalog: [AgentKind] = [.claude, .codex, .antigravity, .opencode]

    /// Only the agents found are named, in the catalog's order, whatever
    /// order they were found in.
    @Test func shown_namesTheFoundAgents_inTheCatalogsOrder() {
        #expect(InstalledAgentRule.shown(catalog: catalog, installed: [.opencode, .claude]) == [.claude, .opencode])
        #expect(InstalledAgentRule.shown(catalog: catalog, installed: []).isEmpty)
    }

    /// Before the agents were looked for once, every one is named, so a
    /// list opened as the app starts names some.
    @Test func shown_beforeAnyLookup_namesEveryAgent() {
        #expect(InstalledAgentRule.shown(catalog: catalog, installed: nil) == catalog)
    }

    /// An agent not found but with something of its own to show, as usage
    /// it reported, is named all the same.
    @Test func shown_alsoNamesAnAgentWithSomethingToShow() {
        let shown = InstalledAgentRule.shown(catalog: catalog, installed: [.codex], alsoShowing: [.claude])
        #expect(shown == [.claude, .codex])
    }

    @Test func addTabOffer_withNoAgentWorking_hasNoNote() {
        let offer = AddTabOffer(catalog: catalog, installed: [.claude, .codex], isAgentWorkingInFolder: false)
        #expect(offer.agents == [.claude, .codex])
        #expect(offer.note == nil)
    }

    @Test func addTabOffer_withAnAgentWorking_saysSoOnce() {
        let offer = AddTabOffer(catalog: catalog, installed: [.claude], isAgentWorkingInFolder: true)
        #expect(offer.note == .agentAlreadyWorking)
    }

    /// With none found, the note says where we looked, whether or not an
    /// agent works in the folder: it is the one that explains the menu.
    @Test func addTabOffer_withNoAgentFound_saysWhereWeLooked() {
        for isWorking in [false, true] {
            let offer = AddTabOffer(catalog: catalog, installed: [], isAgentWorkingInFolder: isWorking)
            #expect(offer.agents.isEmpty)
            #expect(offer.note == .noAgentFound)
        }
    }

    /// Before the lookup, the note never says none was found.
    @Test func addTabOffer_beforeAnyLookup_offersEveryAgent() {
        let offer = AddTabOffer(catalog: catalog, installed: nil, isAgentWorkingInFolder: false)
        #expect(offer.agents == catalog)
        #expect(offer.note == nil)
    }

    @Test func addTabMenu_endsWithTheShell() {
        let offer = AddTabOffer(catalog: catalog, installed: [.codex], isAgentWorkingInFolder: false)
        #expect(AddTabMenu.items(of: offer) == [.agent(.codex), .shell])
        let none = AddTabOffer(catalog: catalog, installed: [], isAgentWorkingInFolder: false)
        #expect(AddTabMenu.items(of: none) == [.shell])
    }
}

@MainActor
struct InstalledAgentsStoreTests {
    private nonisolated static func installation(_ kind: AgentKind) -> AgentInstallation {
        AgentInstallation(kind: kind, executable: "/usr/local/bin/\(kind.rawValue)")
    }

    @Test func aProject_notLookedUp_hasNoAnswer() {
        let store = InstalledAgentsStore { _ in [] }
        #expect(store.installedAgents(for: UUID()) == nil)
        #expect(store.installedAnywhere == nil)
    }

    /// Each project keeps its own lookup, since a project's pane `PATH`
    /// can hold an agent no other project's has.
    @Test func eachProject_keepsItsOwnLookup() async {
        let withCodex = UUID()
        let store = InstalledAgentsStore { projectID in
            projectID == withCodex ? [Self.installation(.claude), Self.installation(.codex)] : [Self.installation(.claude)]
        }
        await store.refresh(projectID: withCodex)
        await store.refresh(projectID: nil)
        #expect(store.installedAgents(for: withCodex) == [.claude, .codex])
        #expect(store.installedAgents(for: nil) == [.claude])
        #expect(store.installedAnywhere == [.claude, .codex])
    }

    /// What the new worktree sheet found is what the "+" then reads.
    @Test func whatTheSheetFound_isKept() {
        let project = UUID()
        let store = InstalledAgentsStore { _ in [] }
        store.record([Self.installation(.opencode)], from: store.beginLookup(for: project))
        #expect(store.installedAgents(for: project) == [.opencode])
    }

    /// A lookup that ends after a newer one leaves the newer answer.
    @Test func anOlderLookup_endingLast_isDropped() {
        let project = UUID()
        let store = InstalledAgentsStore { _ in [] }
        let older = store.beginLookup(for: project)
        let newer = store.beginLookup(for: project)
        store.record([Self.installation(.codex)], from: newer)
        store.record([], from: older)
        #expect(store.installedAgents(for: project) == [.codex])
    }

    /// The sheet's lookup begins, Weir comes to the front and looks again
    /// while the sheet still waits on Git, and the sheet's answer arrives
    /// last: the look made on coming to the front stays.
    @Test func theSheetsLookup_arrivingAfterARefresh_isDropped() async {
        let project = UUID()
        let store = InstalledAgentsStore { _ in [Self.installation(.claude), Self.installation(.antigravity)] }
        let sheets = store.beginLookup(for: project)
        await store.refresh(projectID: project)
        store.record([Self.installation(.claude)], from: sheets)
        #expect(store.installedAgents(for: project) == [.claude, .antigravity])
    }

    /// Lookups of different projects do not drop each other's answers.
    @Test func lookupsOfOtherProjects_doNotDropEachOther() {
        let first = UUID()
        let second = UUID()
        let store = InstalledAgentsStore { _ in [] }
        let older = store.beginLookup(for: first)
        store.record([Self.installation(.codex)], from: store.beginLookup(for: second))
        store.record([Self.installation(.claude)], from: older)
        #expect(store.installedAgents(for: first) == [.claude])
        #expect(store.installedAgents(for: second) == [.codex])
    }

    /// Coming to the front looks again for every project looked up once,
    /// so an agent removed meanwhile leaves the menus.
    @Test func refreshKnown_looksAgainForEveryProjectLookedUp() async {
        let project = UUID()
        let isInstalled = Recorded(true)
        let store = InstalledAgentsStore { _ in isInstalled.value ? [Self.installation(.codex)] : [] }
        await store.refresh(projectID: project)
        isInstalled.value = false
        await store.refreshKnown()
        #expect(store.installedAgents(for: project) == [])
    }
}
