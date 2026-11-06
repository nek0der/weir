// AgentProjectionAdapter+SavingStatus.swift
// Weir — names the adapter's files that this launch keeps and does not write.

import Foundation

extension AgentProjectionAdapter {
    /// The adapter's files kept unread and not written this launch, for the
    /// notice that tells the person (`SavingSuspendedNotice`).
    var suspendedFiles: [URL] {
        [turnDeletions.suspendedFile, forgottenHintQueue.suspendedFile].compactMap(\.self)
    }
}
