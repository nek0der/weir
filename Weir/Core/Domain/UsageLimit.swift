// UsageLimit.swift
// Weir — an agent's plan ran out of usage: when it resets, and which agents it holds.

import Foundation

/// Which of an agent's work a usage limit stops.
package enum UsageLimitScope: String, Codable, Equatable, Hashable, Sendable {
    /// Every session of the agent on this account.
    case account
    /// The sessions going through one service: a CLI that reaches its models
    /// many ways has a limit on each.
    case upstream
    /// The sessions on one model.
    case model

    /// The scope a word names. A word this build does not know says the limit holds
    /// less than the account, as every word but the default does, and reads as the
    /// one that marks no other agent, here as in the Rust model.
    package init(word: String) {
        self = Self(rawValue: word) ?? .upstream
    }

    /// The scope of a limit that says none: one written before limits said,
    /// when the weekly limits of one Claude model were told only by their window.
    /// It stays here, not in the Rust model, because the stop ledger keeps such
    /// limits too, and the ledger never passes through Rust.
    static func ofUnscoped(window: String?) -> Self {
        ["seven_day_opus", "seven_day_sonnet"].contains(window) ? .model : .account
    }
}

/// The usage limit an agent's turn stopped at, as its run reports it.
package struct UsageLimit: Codable, Equatable, Hashable, Sendable {
    /// When the limit resets; `nil` when the provider did not say.
    package var resetAt: Date?
    /// Which limit, as the provider names it (Claude's `five_hour`,
    /// `seven_day`, …); `nil` when not given.
    package var window: String?
    /// Whom the limit holds.
    package var scope: UsageLimitScope
    /// The limit in the provider's own words, for one with no `window` the
    /// interface has a name for; `nil` when not given.
    package var label: String?

    package init(
        resetAt: Date? = nil,
        window: String? = nil,
        scope: UsageLimitScope? = nil,
        label: String? = nil
    ) {
        self.resetAt = resetAt
        self.window = window
        self.scope = scope ?? .ofUnscoped(window: window)
        self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case resetAt, window, scope, label
    }

    /// A limit kept from before the field read as what it was then.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let window = try container.decodeIfPresent(String.self, forKey: .window)
        try self.init(
            resetAt: container.decodeIfPresent(Date.self, forKey: .resetAt),
            window: window,
            scope: (try? container.decodeIfPresent(String.self, forKey: .scope))?.map(UsageLimitScope.init(word:)),
            label: container.decodeIfPresent(String.self, forKey: .label)
        )
    }

    /// Whether the limit holds every agent of the account. One on a single
    /// model or service stops only the agents on it, so it does not mark the
    /// others, and the agent it stopped may go on by changing model.
    var isAccountWide: Bool {
        scope == .account
    }

    /// Whether the reset is known and still ahead at `now`.
    package func resetsLater(than now: Date) -> Bool {
        resetAt.map { $0 > now } ?? false
    }

    /// Of the limits that hold one agent, the one holding it at `now`: the
    /// one that resets last of those still ahead, else one whose reset is
    /// not known; `nil` when every one has reset. A reset that has passed
    /// never hides a limit whose time is not known.
    package static func holding(_ limits: [UsageLimit], at now: Date) -> UsageLimit? {
        let ahead = limits.filter { $0.resetsLater(than: now) }
        if let last = ahead.max(by: { ($0.resetAt ?? now) < ($1.resetAt ?? now) }) {
            return last
        }
        return limits.first { $0.resetAt == nil }
    }
}

/// What a usage limit stop offers instead of resuming while the limit holds:
/// resuming before the reset only meets the limit again, so the bar's
/// primary is "Notify When It Resets", and once asked (or when the setting
/// asks for every reset) the bar says the notice will come.
package enum UsageLimitResetNotice: Equatable, Sendable {
    case offered
    case requested

    /// The notice `item` offers at `now`: a usage limit stop while its
    /// provider is held, judged by the same time the notice is sent at
    /// (`UsageLimits.releaseAt`), so the bar never offers to resume into a
    /// limit that still holds nor to notify of one that has passed. Any
    /// other stop resumes as it would. So does one on a single service: the agent
    /// can go on by changing model, which waiting would hide.
    package static func of(_ item: AttentionItem, in limits: UsageLimits, isRequested: (AgentKind) -> Bool, now: Date) -> Self? {
        guard case let .stop(.usageLimit(limit)) = item.kind, limit.scope != .upstream, let provider = item.subject.provider,
              limits.releaseAt(of: provider, now: now) != nil
        else { return nil }
        return isRequested(provider) ? .requested : .offered
    }
}

/// The usage limits that hold each provider's agents now, read from the
/// attention list's stops: one plan per provider on this Mac stands for the
/// account, so every agent of that provider is held until it resets.
package struct UsageLimits: Equatable, Sendable {
    /// Each limited provider's limits, one per stop. Which holds it is
    /// chosen against the clock (`UsageLimit.holding`), since a reset that
    /// passes changes the answer.
    package private(set) var limits: [AgentKind: [UsageLimit]] = [:]

    /// `lifted` are the stops whose limit no longer holds
    /// (`AttentionQueue.liftedUsageLimits`).
    package init(items: [AttentionItem], lifted: Set<AttentionItemID> = []) {
        for item in items where !lifted.contains(item.id) {
            guard case let .stop(.usageLimit(limit)) = item.kind, let provider = item.subject.provider else { continue }
            limits[provider, default: []].append(limit)
        }
    }

    /// The limits the attention list's stops hold, less the ones since lifted.
    package init(queue: AttentionQueue) {
        self.init(items: queue.items, lifted: queue.liftedUsageLimits)
    }

    /// Whether `runtime` shows the account-wide limit `item` stopped at
    /// lifted: a run of the same provider ended a turn of its own after
    /// the stop. Only a turn the provider served through to its end proves
    /// it. A session started asks nothing of the plan, and a turn under
    /// way may have begun before the limit, or meet it at its next
    /// request. A model's own weekly limit is not lifted by a turn that
    /// may have run on another model.
    ///
    /// Without this, the stop of an agent the person left (they upgraded
    /// the plan, or signed in to another account, and went on in a new
    /// conversation) would mark every row of the provider at its limit,
    /// with no end when the provider gave no reset time.
    package static func isLifted(_ item: AttentionItem, by runtime: RuntimeFact) -> Bool {
        guard case let .stop(.usageLimit(limit)) = item.kind, limit.isAccountWide,
              runtime.provider == item.subject.provider, runtime.state == .finished
        else { return false }
        return runtime.updatedAt > item.arrivedAt
    }

    /// `provider`'s limits that hold every agent of the account, for the
    /// rows they mark.
    package func accountWide(of provider: AgentKind) -> [UsageLimit] {
        (limits[provider] ?? []).filter(\.isAccountWide)
    }

    /// When `provider`'s agents are free again, seen at `now`: the
    /// account-wide limit that resets last; a model's own weekly limit sets
    /// it only when nothing else holds the provider. `nil` when no limit
    /// holds it with a time ahead. One time per provider, as the plan is
    /// the account's: an agent on a model whose own weekly limit outlasts
    /// it is told at that time too, which it learns from its own stop.
    package func releaseAt(of provider: AgentKind, now: Date) -> Date? {
        guard let all = limits[provider] else { return nil }
        let accountWide = all.filter(\.isAccountWide)
        let candidates = accountWide.contains { $0.resetsLater(than: now) || $0.resetAt == nil } ? accountWide : all
        return UsageLimit.holding(candidates, at: now).flatMap { $0.resetsLater(than: now) ? $0.resetAt : nil }
    }

    /// The times after `now` at which what these limits say has changed: a
    /// second past each known reset still ahead. `UsageLimitResetSync`
    /// reads them again then, rather than on a clock, and the views that
    /// word them are drawn again with it.
    package func changeTimes(after now: Date) -> [Date] {
        limits.values.joined().compactMap(\.resetAt).filter { $0 > now }.sorted().map { $0.addingTimeInterval(1) }
    }

    /// The notifications to have pending at `now`: for every limited
    /// provider while the setting asks for every reset, else for the
    /// providers the person asked of from a stop. One per provider, at
    /// its `releaseAt`. A limit with no time, or one past, has none.
    package func pendingResetNotifications(isEnabled: Bool, requested: Set<AgentKind> = [], now: Date) -> [AgentKind: Date] {
        Dictionary(uniqueKeysWithValues: limits.keys.compactMap { provider in
            guard isEnabled || requested.contains(provider), let release = releaseAt(of: provider, now: now) else { return nil }
            return (provider, release)
        })
    }
}
