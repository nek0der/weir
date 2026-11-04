// WindowRegistry+ApprovalCards.swift
// Weir — every window's approval card: opening one from outside any window, and following the requests the windows share.

import Foundation
import WeirDomain

extension WindowRegistry {
    /// Every window's approval card follows the requests as they move
    /// (`ApprovalPresentationStore.onRequestsChanged`): one whose request is
    /// settled closes, and the frames of rows no longer known go.
    func settleApprovalCards(against approvals: ApprovalPresentationStore) {
        for window in windows {
            window.approvalCard.settle(against: approvals)
        }
    }

    /// Opens the card on `key` from outside any window (a notification or
    /// its history row, the menu bar's Answer…), while Weir can answer the
    /// request on it (`WindowApprovalCard.presentToAnswer`): in the window
    /// commands act on, brought back if hidden or minimized, over whatever
    /// it shows (`bringBack`). Returns whether the card opened; no window is
    /// brought back when it does not.
    @discardableResult
    func presentApprovalCardFromOutside(key: ApprovalKey, from approvals: ApprovalPresentationStore) -> Bool {
        guard approvals.opensCard(key) else { return false }
        return bringBack(nil).approvalCard.presentToAnswer(key: key, from: approvals)
    }
}
