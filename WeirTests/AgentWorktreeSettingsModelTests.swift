// AgentWorktreeSettingsModelTests.swift
// Weir — the Agent Worktrees section's rows and note come from capabilities.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Agent worktree settings")
struct AgentWorktreeSettingsModelTests {
    private static let en = Locale(identifier: "en")
    private static let ja = Locale(identifier: "ja")

    private static func model(_ table: [AgentKind: Set<String>]) -> AgentWorktreeSettingsModel {
        AgentWorktreeSettingsModel { capability, kind in table[kind]?.contains(capability) == true }
    }

    @Test func togglesAndTheNoteFollowTheCapabilitiesInCatalogOrder() {
        let model = Self.model([
            .opencode: ["worktree_events", "worktree_finish_proven"],
            .antigravity: ["worktree_events", "worktree_placement"],
            .claude: ["worktree_events", "worktree_placement"],
            .codex: ["worktree_events"]
        ])
        #expect(model.routed == [.claude, .antigravity])
        #expect(model.unrouted == [.codex, .opencode])
        #expect(model.provenAfterward == [.opencode])
    }

    @Test func theRealDescriptorsListEveryAgentButOpenCode() {
        let model = AgentWorktreeSettingsModel()
        #expect(model.routed == [.claude, .codex, .antigravity])
        #expect(model.unrouted == [.opencode])
        #expect(model.provenAfterward == [.opencode])
    }

    @Test func aSentenceWithNothingToNameIsLeftOut() {
        let all = Self.model([.claude: ["worktree_placement"], .codex: ["worktree_placement"]])
        #expect(all.note(locale: Self.en) == nil)
        let unproven = Self.model([.claude: ["worktree_placement"], .codex: ["worktree_events"]])
        #expect(unproven.note(locale: Self.en, name: { $0.rawValue })
            == "codex isn’t listed because Weir can’t step in before it runs a command.")
    }

    @Test func oneNameAndTwoNamesReadRightInEnglishAndJapanese() {
        let one = Self.model([.claude: ["worktree_placement"], .opencode: ["worktree_finish_proven"]])
        let name: (AgentKind) -> String = { $0 == .opencode ? "OpenCode" : "Kiro" }
        #expect(one.note(locale: Self.en, name: name) == """
        OpenCode isn’t listed because Weir can’t step in before it runs a command. \
        A worktree OpenCode makes gets the setup commands only when it lands in this project’s location.
        """)
        #expect(one.note(locale: Self.ja, name: name) == """
        OpenCode は、コマンドの実行前に Weir が処理できないため表示していません。\
        OpenCode が作るワークツリーには、この場所に作られたときだけセットアップコマンドを適用します。
        """)
        let two = Self.model([.codex: ["worktree_finish_proven"], .opencode: ["worktree_finish_proven"]])
        let names: (AgentKind) -> String = { $0 == .opencode ? "OpenCode" : "Kiro" }
        #expect(two.note(locale: Self.en, name: names) == """
        Kiro and OpenCode aren’t listed because Weir can’t step in before they run a command. \
        A worktree Kiro and OpenCode make gets the setup commands only when it lands in this project’s location.
        """)
        #expect(two.note(locale: Self.ja, name: names)?.hasPrefix("Kiro、OpenCode は") == true)
    }

    /// The two sentences run on as the language puts them: one space in English, none
    /// in Japanese, with one name or two.
    @Test func theSentencesJoinAsTheLanguageJoinsThem() throws {
        let name: (AgentKind) -> String = { $0 == .opencode ? "OpenCode" : "Kiro" }
        let models = [
            Self.model([.opencode: ["worktree_finish_proven"]]),
            Self.model([.codex: ["worktree_finish_proven"], .opencode: ["worktree_finish_proven"]])
        ]
        for model in models {
            let names = model.unrouted.map(name)
            for (locale, joiner) in [(Self.en, " "), (Self.ja, "")] {
                let first = try #require(AgentWorktreeSettingsModel.unroutedSentence(names, locale: locale))
                let second = try #require(AgentWorktreeSettingsModel.provenSentence(names, locale: locale))
                #expect(model.note(locale: locale, name: name) == first + joiner + second, "\(locale.identifier) \(names)")
            }
        }
    }

    @MainActor
    @Test func eachToggleReadsAndWritesTheFieldItsAgentAlwaysHad() throws {
        let session = WorkspaceSession()
        let project = Project(name: "p", rootURL: URL(fileURLWithPath: "/tmp/weir-project"))
        session.projects.append(project)
        for kind in [AgentKind.claude, AgentKind.codex, AgentKind.antigravity] {
            session.setProjectRoutesWorktrees(project.id, for: kind, to: false)
        }
        let saved = try #require(session.projects.first { $0.id == project.id })
        #expect(!saved.routeClaudeWorktrees && !saved.routeCodexWorktrees && !saved.routeAntigravityWorktrees)
        #expect(!saved.routesWorktrees(for: AgentKind.codex))
        #expect(saved.routesWorktrees(for: AgentKind.opencode), "no field, no toggle, never off")
        // The saved keys are the ones a project written before this reads back.
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(saved))
        #expect(!decoded.routesWorktrees(for: AgentKind.claude))
        #expect(!decoded.routesWorktrees(for: AgentKind.antigravity))
    }
}
