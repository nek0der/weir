// ProviderCapabilityTableTests.swift
// Weir — each capability that replaced a provider id gives every answer the id gave, and names come from one place.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Provider capability tables")
struct ProviderCapabilityTableTests {
    private static let question = ApprovalQuestion(header: nil, prompt: "Which?", options: [], isMultiSelect: false)

    /// Weir held every question but Codex's, whose TUI answers it.
    @Test("a question is held unless the provider was Codex", arguments: AgentKind.allCases, [false, true])
    func supportsNativeAnswer_keepsTheTable(kind: AgentKind, isQuestion: Bool) {
        let request = ApprovalPresentation.test(provider: kind, questions: isQuestion ? [Self.question] : [])
        #expect(request.supportsNativeAnswer == !(kind == .codex && isQuestion))
    }

    /// A question's turn released it only for Claude, and only with the
    /// helper's mark in its operation id.
    @Test("a question's turn releases it only for Claude", arguments: AgentKind.allCases, [false, true])
    func hasQuestionTurnCompletion_keepsTheTable(kind: AgentKind, isMarked: Bool) {
        let operationID = isMarked ? AgentQuestionTurnCompletion.operationIDPrefix + "turn" : "turn"
        let request = ApprovalPresentation.test(provider: kind, operationID: operationID)
        #expect(request.hasQuestionTurnCompletion == (kind == .claude && isMarked))
        #expect(!ApprovalPresentation.test(provider: kind, operationID: nil).hasQuestionTurnCompletion)
    }

    /// The Hook Helper asked for `provider == "claude"`, `"codex"`, and
    /// `"opencode"`; the capabilities it reads instead say yes for that one
    /// provider each, and nothing for one this build does not have.
    @Test("the helper's capabilities sit on the provider whose id it checked", arguments: AgentKind.allCases)
    func helperCapabilities_keepTheTable(kind: AgentKind) {
        let expected = [
            (ProviderCapabilityName.questionEndsWithTurn, kind == .claude),
            (ProviderCapabilityName.questionAnsweredByAgent, kind == .codex),
            (ProviderCapabilityName.approvalHookRecordsLifecycle, kind == .codex),
            (ProviderCapabilityName.approvalWithdrawnBySignal, kind == .opencode),
            (ProviderCapabilityName.approvalPromptBesideCard, [.claude, .opencode].contains(kind))
        ]
        let capabilities = RustProviderBridge.capabilities(provider: kind.rawValue)
        for (capability, isPresent) in expected {
            #expect(capabilities.contains(capability) == isPresent, "\(capability)")
            #expect(AgentProviderRegistry.has(capability, kind) == isPresent, "\(capability)")
        }
    }

    /// The waits the approval service receives as requests are read from
    /// the descriptors: every permission request of a provider with an
    /// approval hook, and only Claude's questions, since Codex's and
    /// OpenCode's wait at their own prompt and Antigravity has no hook.
    @Test("the service's requests are the descriptors' approval hooks")
    func serviceRequests_comeFromTheDescriptors() {
        #expect(AttentionQueueReducer.ServiceRequests.ofInstalledProviders() == .init(
            approvals: [.claude, .codex, .opencode],
            questions: [.claude]
        ))
    }

    /// The Rust registry and `AgentKind` name the same agents, so a case
    /// added on one side alone fails here.
    @Test("the registry's providers are AgentKind's cases")
    func registry_matchesAgentKind() {
        #expect(Set(AgentProviderRegistry.descriptors.keys) == Set(AgentKind.allCases.map(\.rawValue)))
        #expect(Set(AgentProviderRegistry.recipes.keys) == Set(AgentKind.allCases.map(\.rawValue)))
    }

    @Test("a provider this build does not have has no capability")
    func unknownProvider_hasNone() {
        #expect(RustProviderBridge.capabilities(provider: "later-agent").isEmpty)
        #expect(RustProviderBridge.capabilities(provider: "").isEmpty)
    }

    // MARK: - Names

    /// Review named each agent by its full name; the descriptor gives the same.
    @Test("review names each agent as it did", arguments: AgentKind.allCases)
    func reviewNames_areTheOnesItHad(kind: AgentKind) {
        let expected = switch kind {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .opencode: "OpenCode"
        case .kiro: "Kiro"
        }
        #expect(AgentProviderRegistry.displayName(for: kind) == expected)
    }

    /// The usage-limit notice named each agent by its short name, which the
    /// catalog gives.
    @Test("the usage-limit notice names each agent as it did", arguments: AgentKind.allCases)
    func noticeNames_areTheOnesItHad(kind: AgentKind) {
        let expected = switch kind {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .opencode: "OpenCode"
        case .kiro: "Kiro"
        }
        #expect(AgentCatalog.entry(for: kind).displayName == expected)
    }

    // MARK: - The hook outcome

    @Test("the hook outcome reads every word the bridge writes, and keeps one it does not know")
    func hookOutcome_decodesEveryWord() throws {
        let words: [(String, RustHookOutcome.Kind)] = [
            ("applied", .applied),
            ("not_in_weir", .notInWeir),
            ("rejected", .rejected),
            ("unknown_provider", .unknownProvider),
            ("not_recorded", .notRecorded),
            ("intercepted", .intercepted),
            ("later_word", .other("later_word"))
        ]
        for (word, kind) in words {
            let body = try JSONSerialization.data(withJSONObject: ["outcome": word, "exit_code": 0])
            let outcome = try JSONDecoder().decode(RustHookOutcome.self, from: body)
            #expect(outcome == RustHookOutcome(outcome: kind, exitCode: 0, message: nil), "\(word)")
        }
        let intercepted = try JSONDecoder().decode(
            RustHookOutcome.self,
            from: Data(#"{"outcome":"intercepted","exit_code":2,"message":"routed","stdout":"{}"}"#.utf8)
        )
        #expect(intercepted == RustHookOutcome(outcome: .intercepted, exitCode: 2, message: "routed", stdout: "{}"))
        let missingStatus = #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RustHookOutcome.self, from: Data(#"{"outcome":"applied"}"#.utf8))
        }
        guard case let .keyNotFound(key, _)? = missingStatus else {
            Issue.record("expected a missing required exit status")
            return
        }
        #expect(key.stringValue == "exit_code")

        let malformedOptional = try JSONDecoder().decode(
            RustHookOutcome.self,
            from: Data(#"{"outcome":"applied","exit_code":0,"message":false,"stdout":42}"#.utf8)
        )
        #expect(malformedOptional == RustHookOutcome(outcome: .applied, exitCode: 0, message: nil))
    }
}
