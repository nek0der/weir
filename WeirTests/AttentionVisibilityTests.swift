// AttentionVisibilityTests.swift
// Weir — whether the person sees a pane.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct AttentionVisibilityTests {
    static let first = UUID()
    static let second = UUID()
    static let elsewhere = UUID()

    @Test(arguments: [
        (Set([first, second]), true, Set([first, second])),
        (Set([first, second]), false, Set<UUID>()),
        (Set<UUID>(), true, Set<UUID>()),
        (Set<UUID>(), false, Set<UUID>())
    ])
    func onlyAttendedPanes_areSeenAndOnlyWhileWeirIsActive(
        attended: Set<UUID>,
        isAppActive: Bool,
        expected: Set<UUID>
    ) {
        let visibility = AttentionVisibility(attendedPanes: attended, isAppActive: isAppActive)
        #expect(visibility.seenPanes == expected)
        for pane in [Self.first, Self.second, Self.elsewhere] {
            #expect(visibility.isSeen(pane) == expected.contains(pane))
        }
    }
}
