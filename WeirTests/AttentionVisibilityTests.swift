// AttentionVisibilityTests.swift
// Weir — whether the person sees a pane.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct AttentionVisibilityTests {
    static let pane = UUID()

    /// Seen while Weir is in front and a window attends the pane; a pane
    /// minimized, hidden, covered, zoomed out, or under the review is left
    /// out of the attended set.
    @Test(arguments: [
        (Set([pane]), true, true),
        (Set([pane]), false, false),
        (Set<UUID>(), true, false)
    ])
    func aPane_isSeen_whileWeirIsInFrontAndAWindowAttendsIt(
        attended: Set<UUID>,
        isAppActive: Bool,
        isSeen: Bool
    ) {
        let visibility = AttentionVisibility(attendedPanes: attended, isAppActive: isAppActive)
        #expect(visibility.isSeen(Self.pane) == isSeen)
        #expect(visibility.seenPanes.contains(Self.pane) == isSeen)
    }
}
