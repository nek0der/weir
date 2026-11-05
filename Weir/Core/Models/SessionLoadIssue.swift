// SessionLoadIssue.swift
// Weir — one-line summary of why the persisted session couldn't be restored

import Foundation

enum SessionLoadIssue: Equatable, Identifiable {
    case versionMismatch(found: Int, expected: Int)
    case decodeFailed(message: DisplayText)
    /// The snapshot loaded, but we dropped the tabs whose tab or pane IDs
    /// collided or chose another sidebar item for the one that couldn't be
    /// restored.
    case recovered(droppedTabCount: Int, didResetActiveContainer: Bool)

    var id: String {
        switch self {
        case let .versionMismatch(f, e): "vm:\(f)->\(e)"
        case let .decodeFailed(.verbatim(text)): "df:\(text)"
        case let .decodeFailed(.localized(resource)): "df:\(resource.key)"
        case let .recovered(n, reset): "rc:\(n):\(reset)"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .versionMismatch: "Previous Session Not Restored"
        case .decodeFailed: "Couldn’t Restore the Previous Session"
        case .recovered: "Previous Session Repaired"
        }
    }

    /// The decoder's own message is shown as is: it names the JSON path
    /// that failed, which no catalog string could carry. Our own migration
    /// errors bring a catalog string instead (`DisplayText(error:)`).
    ///
    /// A version mismatch names no schema number: the person cannot act on
    /// it, and `id` and the log keep it. Nor does it say the file was set
    /// aside, since that can fail, and `SavingSuspendedText` then says so
    /// right after this sentence.
    var detail: DisplayText {
        switch self {
        case .versionMismatch:
            .localized(LocalizedStringResource(
                "This session was saved by a different version of Weir, so this version can’t open it. A fresh window was opened instead.",
                comment: "The alert that the previous session was not restored: state.json was written by a version this one cannot read"
            ))
        case let .decodeFailed(message):
            message
        case let .recovered(droppedTabCount, didResetActiveContainer):
            .localized(Self.recoveryDetail(droppedTabCount: droppedTabCount, didResetActiveContainer: didResetActiveContainer))
        }
    }

    /// One whole sentence per combination, so a translation never depends
    /// on how we would join two of them.
    private static func recoveryDetail(droppedTabCount: Int, didResetActiveContainer: Bool) -> LocalizedStringResource {
        if droppedTabCount == 0 {
            return "The selected sidebar item couldn’t be restored, so another one is selected."
        }
        if didResetActiveContainer {
            // swiftlint:disable:next line_length
            return "Removed \(droppedTabCount) tabs with duplicate IDs. The selected sidebar item couldn’t be restored, so another one is selected."
        }
        return "Removed \(droppedTabCount) tabs with duplicate IDs."
    }
}
