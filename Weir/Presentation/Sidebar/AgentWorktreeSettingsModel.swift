// AgentWorktreeSettingsModel.swift
// Weir — which agents the project settings' "Agent Worktrees" section lists, and why the others are not.

import Foundation
import WeirDomain

/// The section's rows and its note, from what each provider's descriptor declares
/// (`AgentProviderRegistry`): an agent Weir can stop before it runs `git worktree add`
/// gets a toggle; the others are named, with why, so their absence does not read as
/// no support. A new provider takes its place here by its descriptor alone.
struct AgentWorktreeSettingsModel: Equatable {
    /// The agents with a toggle, in `AgentKind`'s order.
    let routed: [AgentKind]
    /// The agents Weir cannot step in for before they run a command.
    let unrouted: [AgentKind]
    /// Those of them whose worktree gets the setup after the fact, when it lands at
    /// the placement.
    let provenAfterward: [AgentKind]

    init(kinds: [AgentKind] = AgentKind.allCases, has: (String, AgentKind) -> Bool = AgentProviderRegistry.has) {
        let placement = ProviderCapabilityName.worktreePlacement
        let proven = ProviderCapabilityName.worktreeFinishProven
        let known = kinds.filter {
            has(placement, $0) || has(proven, $0) || has(ProviderCapabilityName.worktreeEvents, $0)
        }
        routed = known.filter { has(placement, $0) }
        unrouted = known.filter { !has(placement, $0) }
        provenAfterward = unrouted.filter { has(proven, $0) }
    }

    /// The paragraph under the footer, `nil` when it has nothing to say. `name` is
    /// how an agent is called (`AgentProviderRegistry.displayName`).
    func note(locale: Locale, name: (AgentKind) -> String = AgentProviderRegistry.displayName) -> String? {
        let sentences = [
            Self.unroutedSentence(unrouted.map(name), locale: locale),
            Self.provenSentence(provenAfterward.map(name), locale: locale)
        ].compactMap(\.self)
        guard !sentences.isEmpty else { return nil }
        // How two sentences run on is the language's: a space in English, none in Japanese.
        return sentences.dropFirst().reduce(sentences[0]) { text, next in
            LocalizedStringResource(
                "\(text) \(next)",
                comment: "Two sentences of a paragraph, one after the other: a space between them where the language puts one"
            ).resolved(in: locale)
        }
    }

    static func list(_ names: [String], locale: Locale) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }

    static func unroutedSentence(_ names: [String], locale: Locale) -> String? {
        guard !names.isEmpty else { return nil }
        let list = list(names, locale: locale)
        // One agent takes the singular verbs, which only English shows.
        if names.count == 1 {
            return LocalizedStringResource(
                "\(list) isn’t listed because Weir can’t step in before it runs a command.",
                comment: "Project settings, Agent Worktrees: one agent without a hook before its tools; the argument is its name"
            ).resolved(in: locale)
        }
        return LocalizedStringResource(
            "\(list) aren’t listed because Weir can’t step in before they run a command.",
            comment: "Project settings, Agent Worktrees: agents without a hook before their tools; the argument is their names as a list"
        ).resolved(in: locale)
    }

    static func provenSentence(_ names: [String], locale: Locale) -> String? {
        guard !names.isEmpty else { return nil }
        let list = list(names, locale: locale)
        if names.count == 1 {
            return LocalizedStringResource(
                "A worktree \(list) makes gets the setup commands only when it lands in this project’s location.",
                comment: "Project settings, Agent Worktrees: one agent whose worktree gets setup afterward; the argument is its name"
            ).resolved(in: locale)
        }
        return LocalizedStringResource(
            "A worktree \(list) make gets the setup commands only when it lands in this project’s location.",
            comment: "Project settings, Agent Worktrees: agents whose worktrees get setup afterward; the argument is their names as a list"
        ).resolved(in: locale)
    }
}
