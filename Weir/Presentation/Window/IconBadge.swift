// IconBadge.swift
// Weir — what an icon control carries: a count, a dot, or nothing.

import Foundation
import WeirDomain

/// The mark on an icon control. A count where the number is what to act
/// on (the changes panel's turns waiting to be read); a dot where only
/// "something is there" is (unread history), so the bell's number is not
/// read as a count of what needs attention beside the title bar's
/// Needs Attention count. `nil` at a call site means no mark.
enum IconBadge: Equatable {
    /// What a count's color says.
    enum CountTone: Equatable {
        case unread
        case blocking
    }

    /// A count above zero; build it with `counting(_:tone:)`, which gives no
    /// mark at zero.
    case count(Int, tone: CountTone = .unread)
    case dot
    /// Something waits on the person (an agent, a plan usage window near its
    /// limit): the unread dot in the waiting color.
    case waiting
    /// Something stopped (an agent, a window at its limit): drawn larger and
    /// in the stopped color, so it differs from waiting by more than hue.
    case stopped

    /// A count, or nothing at zero.
    static func counting(_ count: Int, tone: CountTone = .unread) -> IconBadge? {
        count > 0 ? .count(count, tone: tone) : nil
    }

    /// The mark for a place's state: what asks something of the person, and
    /// none for what does not.
    static func state(of glyph: SessionRowFact.Glyph) -> IconBadge? {
        switch glyph {
        case .needsAnswer, .needsApproval, .needsResponse, .needsSignIn: .waiting
        case .stopped: .stopped
        case .unread, .unreadWorkingAfterTurn: .dot
        case .running, .idle, .workingAfterTurn, .unknown, .shell: nil
        }
    }

    /// Past two digits a count says "99+", not a bare 99, which reads as
    /// an exact count.
    static func text(for count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }
}
