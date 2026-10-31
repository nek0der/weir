// NotificationHistoryRailText.swift
// Weir — what the left rail's bell carries and says.

import Foundation

/// The notification history's bell on the left rail: a dot while anything
/// is unread, and the count only in its VoiceOver value.
enum NotificationHistoryRailText {
    static func badge(unread: Int) -> IconBadge? {
        unread > 0 ? .dot : nil
    }

    /// What VoiceOver reads after the bell's name; `nil` when nothing is
    /// unread, so it reads the name alone.
    static func unreadCount(_ unread: Int, locale: Locale) -> String? {
        guard unread > 0 else { return nil }
        return LocalizedStringResource("\(unread) unread").resolved(in: locale)
    }
}
