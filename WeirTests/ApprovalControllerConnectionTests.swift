// ApprovalControllerConnectionTests.swift
// Weir — what the app reads out of the broker's replies: the pending list,
// how tracked requests ended, the service clock, and a refused decision.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct ApprovalControllerConnectionTests {
    private static let now = SuspendingClock.now

    @Test func inputDetails_addMoreThanACommandAndItsDescription() {
        let inputAdds = ApprovalControllerConnection.inputAddsToSummary
        #expect(!inputAdds(["command": "ls", "description": "List"], "ls"))
        #expect(!inputAdds(["command": "ls"], "ls"))
        #expect(inputAdds(["command": "ls", "timeout": 5], "ls"))
        #expect(inputAdds(["file_path": "/a", "content": "b"], "/a"))
        #expect(inputAdds(["command": ["ls", "-l"]], "ls -l"))
        #expect(inputAdds(["command": "ls"], "a description"))
    }

    /// One row of the broker's snapshot index for `approval`.
    private static func index(
        _ approval: ApprovalPresentation,
        status: String = "pending",
        deadline: UInt64 = 600_000
    ) -> [String: Any] {
        [
            "run_id": approval.runID.uuidString,
            "request_id": approval.requestID.uuidString,
            "provider": "claude",
            "status": status,
            "deadline_ms": NSNumber(value: deadline),
            "sequence": NSNumber(value: 1)
        ]
    }

    /// The broker's reply to a lookup of one request, in `state`.
    private static func detail(_ state: [String: Any]) -> [String: Any] {
        [
            "type": "approval.result",
            "body": [
                "request": [
                    "provider": "claude",
                    "tool_name": "Bash",
                    "input": ["command": "make test"]
                ],
                "state": state,
                "created_at_ms": NSNumber(value: 0),
                "deadline_ms": NSNumber(value: 600_000),
                "sequence": NSNumber(value: 1)
            ]
        ]
    }

    private static func error(_ code: String) -> [String: Any] {
        ["type": "error", "body": ["code": code, "message": "refused"]]
    }

    // MARK: - The projection

    @Test func aProjection_readsPendingAndLooksUpOnlyTrackedEndings() throws {
        let epoch = UUID()
        let pending = ApprovalPresentation.test(epoch: epoch)
        let tracked = ApprovalPresentation.test(epoch: epoch)
        let untracked = ApprovalPresentation.test(epoch: epoch)
        let evicted = ApprovalPresentation.test(epoch: epoch)
        let response: [String: Any] = [
            "type": "approval.snapshot.result",
            "body": [
                "sequence": NSNumber(value: 7),
                "now_ms": NSNumber(value: 30000),
                "requests": [
                    Self.index(pending, status: "pending"),
                    Self.index(tracked, status: "resolved"),
                    Self.index(untracked, status: "expired")
                ]
            ]
        ]
        var fetched: [ApprovalKey] = []

        let projection = try ApprovalControllerConnection.projection(
            from: response,
            epoch: epoch,
            receivedAt: Self.now,
            trackedIDs: [tracked.id, evicted.id]
        ) { runID, requestID in
            let key = ApprovalKey(epoch: epoch, runID: runID, requestID: requestID)
            fetched.append(key)
            switch key {
            case pending.key: return Self.detail(["status": "pending"])
            case tracked.key: return Self.detail(["status": "resolved", "result": ["decision": "delegate"]])
            default: throw AgentIntegrationError.invalidResponse
            }
        }

        #expect(projection.sequence == 7)
        #expect(projection.requests.map(\.key) == [pending.key])
        let shown = try #require(projection.requests.first)
        #expect(shown.provider == .claude)
        #expect(shown.toolName == "Bash")
        #expect(shown.command == "make test")
        #expect(shown.hasInputCommand)
        #expect(shown.deadlineMilliseconds == 600_000)
        #expect(shown.questions.isEmpty)
        #expect(projection.deadlines.mapValues { $0.remaining(at: Self.now) } == [pending.id: .seconds(570)])
        #expect(projection.terminals == [tracked.id: .resolved(.delegate)])
        #expect(projection.missingIDs == [evicted.id])
        // No split reported: every record counts.
        #expect(projection.unevictableCount == 3)
        #expect(fetched.count == 2)
        #expect(Set(fetched) == [pending.key, tracked.key])
    }

    @Test func aLookupThatFindsNothing_countsAsMissing() throws {
        let epoch = UUID()
        let tracked = ApprovalPresentation.test(epoch: epoch)
        let response: [String: Any] = [
            "type": "approval.snapshot.result",
            "body": ["sequence": NSNumber(value: 1), "requests": [Self.index(tracked, status: "canceled")]]
        ]

        let projection = try ApprovalControllerConnection.projection(
            from: response,
            epoch: epoch,
            receivedAt: Self.now,
            trackedIDs: [tracked.id]
        ) { _, _ in
            Self.error("not_found")
        }

        #expect(projection.missingIDs == [tracked.id])
        #expect(projection.terminals.isEmpty)
    }

    @Test func aReportedSplit_isWhatCapacityCounts() throws {
        let epoch = UUID()
        let pending = ApprovalPresentation.test(epoch: epoch)
        let resolved = ApprovalPresentation.test(epoch: epoch)
        let canceled = ApprovalPresentation.test(epoch: epoch)
        let response: [String: Any] = [
            "type": "approval.snapshot.result",
            "body": [
                "sequence": NSNumber(value: 1),
                "requests": [Self.index(pending), Self.index(resolved, status: "resolved"), Self.index(canceled, status: "canceled")],
                // The pending record and the resolved result the hook has yet to consume.
                "unevictable_records": NSNumber(value: 2)
            ]
        ]
        let projection = try ApprovalControllerConnection.projection(
            from: response,
            epoch: epoch,
            receivedAt: Self.now,
            trackedIDs: []
        ) { runID, requestID in
            try #require(runID == pending.runID && requestID == pending.requestID)
            return Self.detail(["status": "pending"])
        }
        #expect(projection.requests.map(\.key) == [pending.key])
        #expect(projection.unevictableCount == 2)
    }

    @Test func brokerStates_mapToEndings() {
        func ending(_ state: [String: Any]) -> BrokerTerminal? {
            ApprovalControllerConnection.brokerTerminal(fromDetail: ["type": "approval.result", "body": ["state": state]])
        }
        #expect(ending(["status": "resolved", "result": ["decision": "allow_once"]]) == .resolved(.allowOnce))
        #expect(ending(["status": "resolved", "result": ["decision": "deny", "message": "no"]]) == .resolved(.deny))
        #expect(ending(["status": "resolved", "result": ["decision": "answer", "answers": ["Q": "A"]]])
            == .resolved(.answer(["Q": "A"])))
        #expect(ending(["status": "canceled"]) == .canceled)
        #expect(ending(["status": "expired"]) == .expired)
        #expect(ending(["status": "pending"]) == nil)
        #expect(ending(["status": "resolved", "result": ["decision": "answer", "answers": "garbled"]]) == nil)
        #expect(ending(["status": "resolved", "result": ["decision": "allow_always"]]) == nil)
    }

    @Test func presentation_readsQuestionsFromTheRequestDetail() throws {
        let epoch = UUID()
        let runID = UUID()
        let requestID = UUID()
        let detail: [String: Any] = [
            "type": "approval.result",
            "body": [
                "request": [
                    "provider": "claude",
                    "tool_name": "AskUserQuestion",
                    "input": ["description": "Choose"],
                    "questions": [
                        [
                            "header": "Color",
                            "prompt": "Which color?",
                            "multi_select": true,
                            "options": [["label": "Red", "description": "warm"], ["label": "Blue"], ["description": "invalid"]]
                        ],
                        ["header": "Invalid"],
                        ["prompt": "Which size?"]
                    ]
                ],
                "deadline_ms": NSNumber(value: 600_000)
            ]
        ]

        let shown = try ApprovalControllerConnection.presentation(from: detail, epoch: epoch, runID: runID, requestID: requestID)

        #expect(shown.key == ApprovalKey(epoch: epoch, runID: runID, requestID: requestID))
        #expect(shown.toolName == "AskUserQuestion")
        #expect(shown.isQuestion)
        #expect(shown.questions == [
            ApprovalQuestion(header: "Color", prompt: "Which color?", options: [
                .init(label: "Red", description: "warm"), .init(label: "Blue", description: nil)
            ], isMultiSelect: true),
            ApprovalQuestion(header: nil, prompt: "Which size?", options: [], isMultiSelect: false)
        ])
        #expect(ApprovalQuestion.decode(nil).isEmpty)
    }

    @Test func presentationID_distinguishesEpochRunAndRequest() throws {
        let epoch = UUID()
        let run = UUID()
        let request = UUID()
        let keys = [
            ApprovalKey(epoch: epoch, runID: run, requestID: request),
            ApprovalKey(epoch: UUID(), runID: run, requestID: request),
            ApprovalKey(epoch: epoch, runID: UUID(), requestID: request),
            ApprovalKey(epoch: epoch, runID: run, requestID: UUID())
        ]
        let presentations = try keys.map { key in
            try ApprovalControllerConnection.presentation(
                from: Self.detail(["status": "pending"]), epoch: key.epoch, runID: key.runID, requestID: key.requestID
            )
        }
        #expect(presentations.map(\.key) == keys)
        #expect(Set(presentations.map(\.id)).count == keys.count)
    }

    // MARK: - The service clock

    @Test func snapshotBody_givesEachPendingRequestItsTimeLeft() {
        let epoch = UUID()
        let held = ApprovalPresentation.test(epoch: epoch)
        let earlier = ApprovalPresentation.test(epoch: epoch)
        let answered = ApprovalPresentation.test(epoch: epoch)
        let body: [String: Any] = [
            "sequence": NSNumber(value: 4),
            "now_ms": NSNumber(value: 30000),
            "requests": [Self.index(held), Self.index(earlier, deadline: 95000), Self.index(answered, status: "resolved")]
        ]

        let deadlines = ApprovalControllerConnection.serviceDeadlines(fromSnapshotBody: body, epoch: epoch, receivedAt: Self.now)

        #expect(deadlines.mapValues { $0.remaining(at: Self.now) } == [held.id: .seconds(570), earlier.id: .seconds(65)])
    }

    @Test func aBodyWithoutTheServiceClock_givesNoDeadlines() {
        let epoch = UUID()
        let body: [String: Any] = [
            "sequence": NSNumber(value: 1),
            "requests": [Self.index(ApprovalPresentation.test(epoch: epoch))]
        ]

        let deadlines = ApprovalControllerConnection.serviceDeadlines(fromSnapshotBody: body, epoch: epoch, receivedAt: Self.now)

        #expect(deadlines.isEmpty)
    }

    // MARK: - A refused decision

    @Test func alreadyTerminal_asksTheBrokerHowItEnded() throws {
        var fetches = 0
        let refusal = try ApprovalControllerConnection.refusal(of: Self.error("already_terminal")) {
            fetches += 1
            return Self.detail(["status": "resolved", "result": ["decision": "delegate"]])
        }

        #expect(refusal == .alreadySettled(.resolved(.delegate)))
        #expect(fetches == 1)
    }

    /// A record the broker no longer has is missing whether the refusal says
    /// so itself, which needs no lookup, or the lookup after it does.
    @Test(arguments: [("not_found", 0), ("already_terminal", 1)])
    func notFound_isAMissingRecord(code: String, expectedFetches: Int) throws {
        var fetches = 0
        let refusal = try ApprovalControllerConnection.refusal(of: Self.error(code)) {
            fetches += 1
            return Self.error("not_found")
        }

        #expect(refusal == .recordMissing)
        #expect(fetches == expectedFetches)
    }

    /// A lookup that says the request is still pending contradicts the
    /// refusal, and any other code is no settlement at all: both leave the
    /// decision to be tried again.
    @Test(arguments: [("already_terminal", 1), ("epoch_mismatch", 0)])
    func anUnsettledRefusal_isAFailureToRetry(code: String, expectedFetches: Int) {
        var fetches = 0
        let error = #expect(throws: AgentIntegrationError.self) {
            try ApprovalControllerConnection.refusal(of: Self.error(code)) {
                fetches += 1
                return Self.detail(["status": "pending"])
            }
        }
        guard case .invalidResponse? = error else {
            Issue.record("Expected the invalid response error")
            return
        }
        #expect(fetches == expectedFetches)
    }

    @Test func aLookupThatFails_passesItsErrorOn() {
        struct LookupFailed: Error {}
        #expect(throws: LookupFailed.self) {
            try ApprovalControllerConnection.refusal(of: Self.error("already_terminal")) {
                throw LookupFailed()
            }
        }
    }

    // MARK: - Sending before quit

    private struct QuitExchange: Equatable {
        let type: String
        let epoch: UUID
        let runID: UUID
        let requestID: UUID
        let decision: String
        let answers: [String: String]?
        let timeoutSeconds: Int

        init(_ approval: ApprovalPresentation, decision: String, answers: [String: String]? = nil, timeoutSeconds: Int) {
            type = "approval.resolve"
            epoch = approval.epoch
            runID = approval.runID
            requestID = approval.requestID
            self.decision = decision
            self.answers = answers
            self.timeoutSeconds = timeoutSeconds
        }

        init(object: [String: Any], timeoutSeconds: Int) throws {
            let body = try #require(object["body"] as? [String: Any])
            let decision = try #require(body["decision"] as? [String: Any])
            type = try #require(object["type"] as? String)
            epoch = try #require((object["service_epoch"] as? String).flatMap(UUID.init(uuidString:)))
            runID = try #require((body["run_id"] as? String).flatMap(UUID.init(uuidString:)))
            requestID = try #require((body["request_id"] as? String).flatMap(UUID.init(uuidString:)))
            self.decision = try #require(decision["decision"] as? String)
            answers = decision["answers"] as? [String: String]
            self.timeoutSeconds = timeoutSeconds
        }
    }

    private final class QuitExchanges {
        var sent: [QuitExchange] = []

        func exchange(_ request: Data, timeoutSeconds: Int) throws -> Data {
            let object = try AgentIntegrationApprovalWire.object(from: request)
            try sent.append(QuitExchange(object: object, timeoutSeconds: timeoutSeconds))
            return Data()
        }
    }

    @Test func sendBeforeQuit_startsItsBudgetOnceTheSessionIsOpen() {
        let epoch = UUID()
        let request = ApprovalPresentation.test(epoch: epoch)
        let exchanges = QuitExchanges()
        var now = ContinuousClock.now

        ApprovalControllerConnection.sendBeforeQuit(
            [(request, .allowOnce)], budget: .milliseconds(2250), now: { now },
            open: {
                now += .seconds(20)
                return (epoch, exchanges.exchange)
            }
        )

        #expect(exchanges.sent == [QuitExchange(request, decision: "allow_once", timeoutSeconds: 3)])
    }

    @Test func sendBeforeQuit_aFailedExchange_doesNotStopTheRest() {
        struct Dropped: Error {}
        let epoch = UUID()
        let failing = ApprovalPresentation.test(epoch: epoch)
        let following = ApprovalPresentation.test(epoch: epoch)
        let exchanges = QuitExchanges()
        let now = ContinuousClock.now
        let answers = ["Which color?": "Blue"]

        ApprovalControllerConnection.sendBeforeQuit(
            [(failing, .delegate), (following, .answer(answers))],
            budget: .seconds(2),
            now: { now },
            open: {
                (epoch, { request, timeoutSeconds in
                    let reply = try exchanges.exchange(request, timeoutSeconds: timeoutSeconds)
                    if exchanges.sent.count == 1 {
                        throw Dropped()
                    }
                    return reply
                })
            }
        )

        #expect(exchanges.sent == [
            QuitExchange(failing, decision: "delegate", timeoutSeconds: 2),
            QuitExchange(following, decision: "answer", answers: answers, timeoutSeconds: 2)
        ])
    }

    @Test func sendBeforeQuit_stopsOnceTheBudgetIsSpent() {
        let epoch = UUID()
        let first = ApprovalPresentation.test(epoch: epoch)
        let second = ApprovalPresentation.test(epoch: epoch)
        let third = ApprovalPresentation.test(epoch: epoch)
        let exchanges = QuitExchanges()
        var now = ContinuousClock.now

        ApprovalControllerConnection.sendBeforeQuit(
            [(first, .delegate), (second, .delegate), (third, .delegate)], budget: .milliseconds(2250), now: { now },
            open: {
                (epoch, { request, timeoutSeconds in
                    let reply = try exchanges.exchange(request, timeoutSeconds: timeoutSeconds)
                    now += exchanges.sent.count == 1 ? .milliseconds(1500) : .milliseconds(750)
                    return reply
                })
            }
        )

        #expect(exchanges.sent == [
            QuitExchange(first, decision: "delegate", timeoutSeconds: 3),
            QuitExchange(second, decision: "delegate", timeoutSeconds: 1)
        ])
    }

    @Test func sendBeforeQuit_skipsARequestOfAnotherEpoch() {
        let epoch = UUID()
        let current = ApprovalPresentation.test(epoch: epoch)
        let earlier = ApprovalPresentation.test(epoch: UUID(), runID: current.runID, requestID: current.requestID)
        let exchanges = QuitExchanges()
        let now = ContinuousClock.now

        ApprovalControllerConnection.sendBeforeQuit(
            [(earlier, .allowOnce), (current, .delegate)], budget: .seconds(2), now: { now },
            open: { (epoch, exchanges.exchange) }
        )

        #expect(exchanges.sent == [QuitExchange(current, decision: "delegate", timeoutSeconds: 2)])
    }
}
