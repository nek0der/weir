// GhosttyAvailabilityTests.swift
// Weir — a run that requires the FFI tests fails when the test host has no libghostty.

import Testing
@testable import Weir

struct GhosttyAvailabilityTests {
    /// The FFI tests skip themselves without libghostty, so this is the one
    /// test that turns a host that failed to start it into a failure.
    @Test(.tags(.ffi), .enabled(if: GhosttyAvailability.isRequired, "The run does not require libghostty"))
    func theTestHost_startsLibghostty_whenTheRunRequiresIt() async {
        let isAvailable = await GhosttyAvailability.isAvailable()
        let failure = await MainActor.run { TestHostDiagnostics.ghosttyStartFailure }
        #expect(
            isAvailable,
            "WEIR_REQUIRE_GHOSTTY_TESTS is set, but the test host did not start libghostty: \(failure ?? "no error was recorded")"
        )
    }
}
