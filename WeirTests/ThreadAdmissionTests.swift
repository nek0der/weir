// ThreadAdmissionTests.swift
// Weir — the approval service admits requester threads up to its limit.

import Testing
@testable import Weir

struct ThreadAdmissionTests {
    @Test(arguments: [1, 256])
    func admission_refusesAtTheLimit_andOneReleaseMakesRoomForOneRequest(limit: Int) throws {
        let admission = ThreadAdmission(limit: limit)
        for _ in 0..<limit {
            try #require(admission.admit())
        }
        #expect(!admission.admit())
        #expect(!admission.admit())

        admission.release()

        #expect(admission.admit())
        #expect(!admission.admit())
    }
}
