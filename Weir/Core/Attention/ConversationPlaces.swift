// ConversationPlaces.swift
// Weir — which conversation each pane runs and what its provider calls it, apart from what the run is doing.

import Foundation
import WeirDomain

/// What the runs say of where each conversation is, without what each run is
/// doing. The changes panel and its title bar button read this rather than
/// the runs: a run's activity and time change on every hook, and a reader of
/// the runs would build all its turns again each time, though none of what
/// it shows changed. Each rule resolves the run it picks here, so the value
/// holds no time and changes only when a pane's conversation or a provider's
/// title does.
struct ConversationPlaces: Equatable {
    /// A conversation in one pane.
    struct PaneConversation: Hashable {
        let paneID: UUID
        let conversation: ConversationKey
    }

    /// The titles the provider gives a conversation, as its run last
    /// reported them; resolved to one title where they are shown.
    struct ProviderTitles: Equatable {
        let session: String?
        let generated: String?
    }

    /// The conversation each pane's header speaks for, by the header's own
    /// rule (`AttentionState.headerRuntime(inPane:among:)`).
    private(set) var headerConversation: [UUID: ConversationKey] = [:]
    /// The provider's titles of each conversation in each pane where it
    /// runs: those of its latest run there whose state is known.
    private(set) var providerTitles: [PaneConversation: ProviderTitles] = [:]
    /// The conversations whose sessions run in each pane behind the tab on
    /// screen, in the runs' order (`AgentRuntimePresentation.panesBehindShownTab`):
    /// still run there, though the header speaks for the one in front.
    private(set) var behindShownTab: [UUID: [ConversationKey]] = [:]

    init() {}

    init(runtimes: [AgentRuntimePresentation]) {
        var panes: Set<UUID> = []
        var latest: [PaneConversation: AgentRuntimePresentation] = [:]
        for runtime in runtimes {
            panes.formUnion(runtime.paneIDs)
            guard let conversation = runtime.conversation, runtime.badge.state != .unknown else { continue }
            for paneID in runtime.panesBehindShownTab {
                behindShownTab[paneID, default: []].append(conversation)
            }
            for paneID in runtime.paneIDs {
                let key = PaneConversation(paneID: paneID, conversation: conversation)
                // The latest, and the first of two as late, as `max(by:)`
                // over `updatedAt` keeps it.
                if let kept = latest[key], kept.badge.updatedAt >= runtime.badge.updatedAt {
                    continue
                }
                latest[key] = runtime
            }
        }
        for paneID in panes {
            if let conversation = AttentionState.headerRuntime(inPane: paneID, among: runtimes)?.conversation {
                headerConversation[paneID] = conversation
            }
        }
        providerTitles = latest.mapValues {
            ProviderTitles(session: $0.badge.providerSessionTitle, generated: $0.badge.providerGeneratedTitle)
        }
    }
}
