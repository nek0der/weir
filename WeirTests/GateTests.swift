// GateTests.swift
// Weir — bounded observation of calls whose responses a test holds.

import Foundation
import Testing

struct GateTests {
    @Test func aMissingCall_timesOutBeforeTheResponseIsReleased() async {
        let gate = Gate<Void>()
        let failure = Recorded<Gate<Void>.RequestTimeout?>(nil)
        let waiting = Task {
            do {
                try await gate.waitUntilRequested(timeout: .zero)
            } catch let error as Gate<Void>.RequestTimeout {
                failure.value = error
            } catch {
                Issue.record(error)
            }
        }
        await pollUntil { failure.value != nil }
        let observed = failure.value
        // A broken observer must not leave this self-test waiting forever.
        gate.open()
        await gate.wait()
        await waiting.value

        #expect(observed == Gate<Void>.RequestTimeout(expected: 1, actual: 0))
    }

    @Test(arguments: [false, true])
    func cancellation_endsObservationWithoutACall(afterObservationStarts: Bool) async throws {
        let gate = Gate<Void>()
        let canceled = Recorded(false)
        let waiting = Task {
            if !afterObservationStarts {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            do {
                try await gate.waitUntilRequested(timeout: .seconds(60))
            } catch is CancellationError {
                canceled.value = true
            } catch {
                Issue.record(error)
            }
        }
        if afterObservationStarts {
            await pollUntil { gate.observingCount == 1 }
        }
        let didRegister = gate.observingCount == 1
        if afterObservationStarts && didRegister {
            waiting.cancel()
        }
        if !afterObservationStarts || didRegister {
            await pollUntil { canceled.value }
        }
        let observed = canceled.value
        let requestsBeforeCleanup = gate.requests
        // This also releases a broken observer, so no prerequisite can strand its task.
        gate.open()
        await gate.wait()
        await waiting.value

        if afterObservationStarts {
            try #require(didRegister)
        }
        #expect(requestsBeforeCleanup == 0)
        #expect(observed)
        #expect(gate.observingCount == 0)
    }

    @Test func observingTwoCalls_doesNotReleaseTheirResponses() async throws {
        let gate = Gate<Int>()
        let returned = Recorded(0)
        async let first: Int = {
            let value = await gate.wait()
            returned.update { $0 += 1 }
            return value
        }()
        async let second: Int = {
            let value = await gate.wait()
            returned.update { $0 += 1 }
            return value
        }()
        defer { gate.open(with: 42) }

        try await gate.waitUntilRequested(2)
        #expect(gate.requests == 2)
        #expect(returned.value == 0)
        gate.open(with: 42)
        #expect(await first == 42)
        #expect(await second == 42)
    }
}
