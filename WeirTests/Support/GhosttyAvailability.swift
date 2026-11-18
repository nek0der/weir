// GhosttyAvailability.swift
// Weir — whether libghostty is loaded, for the tests that need a real terminal surface.

import Foundation
@testable import Weir

enum GhosttyAvailability {
    /// Whether the app host loaded libghostty. A test bundle run without
    /// it has no terminal to make, which is a missing precondition rather
    /// than a failure, so the FFI tests are enabled on this.
    nonisolated static func isAvailable() async -> Bool {
        await MainActor.run { GhosttyApp.placeholder.target != nil }
    }

    /// Whether the run must have libghostty, as CI's does: a host that
    /// failed to start it would otherwise skip every FFI test without a
    /// word. CI sets `TEST_RUNNER_WEIR_REQUIRE_GHOSTTY_TESTS`, which
    /// xcodebuild passes to the test process without its prefix.
    static let isRequired = ProcessInfo.processInfo.environment["WEIR_REQUIRE_GHOSTTY_TESTS"] == "1"
}
