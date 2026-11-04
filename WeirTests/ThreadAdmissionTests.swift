// ThreadAdmissionTests.swift
// Weir — the approval service admits requester threads up to its limit.

import Testing
@testable import Weir

struct ThreadAdmissionTests {
    @Test func admit_upToTheLimit_thenRefuses() {
        let admission = ThreadAdmission(limit: 256)
        let admitted = (0..<256).map { _ in admission.admit() }
        #expect(!admitted.contains(false))
        #expect(!admission.admit())
    }

    @Test func release_admitsAnotherAgain() {
        let admission = ThreadAdmission(limit: 256)
        for _ in 0..<256 {
            _ = admission.admit()
        }
        #expect(!admission.admit())
        admission.release()
        #expect(admission.admit())
        #expect(!admission.admit())
    }
}
