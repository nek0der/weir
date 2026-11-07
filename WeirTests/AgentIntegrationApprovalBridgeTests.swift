// AgentIntegrationApprovalBridgeTests.swift
// Weir — Swift-to-Rust approval session boundary tests.

import Foundation
import Testing
import WeirRustBridge
@testable import Weir
@testable import WeirDomain

struct AgentIntegrationApprovalBridgeTests {
    @Test func requesterCancellationCancelsOnlyTheNamedQuestionOfItsRun() throws {
        let service = try RustApprovalService(maximumRecords: 8)
        let runID = UUID()
        let requestID = UUID()
        let otherRequestID = UUID()
        let requester = try service.requesterSession(runID: runID)
        let controller = try service.controllerSession()
        let epoch = try completeHello(on: requester)
        _ = try completeHello(on: controller)
        for id in [requestID, otherRequestID] {
            let response = try AgentIntegrationApprovalWire.object(from: requester.exchange(AgentIntegrationApprovalWire.submit(
                epoch: epoch,
                submission: AgentIntegrationApprovalSubmission(
                    runID: runID, requestID: id, provider: "claude", sessionID: "session",
                    operationID: nil, toolName: "AskUserQuestion", summary: nil,
                    input: ["questions": [["question": "Which color?"]]],
                    questions: nil, timeoutMilliseconds: 60000
                )
            )))
            try #require(try state(of: response)["status"] as? String == "pending")
        }
        let canceled = try AgentIntegrationApprovalWire.object(from: requester.exchange(
            AgentIntegrationApprovalWire.cancel(epoch: epoch, runID: runID, requestID: requestID)
        ))
        #expect(ApprovalControllerConnection.brokerTerminal(fromDetail: canceled) == .canceled)
        let fromController = try get(on: controller, epoch: epoch, runID: runID, requestID: requestID)
        #expect(ApprovalControllerConnection.brokerTerminal(fromDetail: fromController) == .canceled)
        let remaining = try AgentIntegrationApprovalWire.object(from: controller.exchange(
            AgentIntegrationApprovalWire.get(epoch: epoch, runID: runID, requestID: otherRequestID)
        ))
        #expect(try state(of: remaining)["status"] as? String == "pending")
    }

    /// The broker refuses a field it does not know, so the run that asked
    /// has to travel under a name it reads, and come back out of it.
    @Test func theAskingAgentRun_reachesTheControllersRequest() throws {
        let service = try RustApprovalService(maximumRecords: 8)
        let runID = UUID()
        let requestID = UUID()
        let agentRunID = UUID()
        let requester = try service.requesterSession(runID: runID)
        let controller = try service.controllerSession()
        let epoch = try completeHello(on: requester)
        _ = try completeHello(on: controller)
        let submitted = try AgentIntegrationApprovalWire.object(from: requester.exchange(
            AgentIntegrationApprovalWire.submit(
                epoch: epoch,
                submission: AgentIntegrationApprovalSubmission(
                    runID: runID, requestID: requestID, provider: "claude", sessionID: "session",
                    operationID: nil, toolName: "Bash", summary: nil, input: ["command": "ls"],
                    questions: nil, timeoutMilliseconds: 60000, agentRunID: agentRunID
                )
            )
        ))
        #expect(submitted["type"] as? String == "approval.result")

        let detail = try AgentIntegrationApprovalWire.object(from: controller.exchange(
            AgentIntegrationApprovalWire.get(epoch: epoch, runID: runID, requestID: requestID)
        ))
        let request = try ApprovalControllerConnection.presentation(
            from: detail, epoch: epoch, runID: runID, requestID: requestID
        )
        #expect(request.agentRunID == agentRunID)
    }

    @Test func requesterAndControllerShareRustBroker() throws {
        let service = try RustApprovalService(maximumRecords: 8)
        let runID = UUID()
        let requestID = UUID()
        let requester = try service.requesterSession(runID: runID)
        let controller = try service.controllerSession()
        let epoch = try completeHello(on: requester)
        #expect(try completeHello(on: controller) == epoch)

        _ = try AgentIntegrationProbeWire.requireType(
            "approval.result",
            in: requester.exchange(AgentIntegrationProbeWire.submit(
                epoch: epoch,
                runID: runID,
                requestID: requestID
            ))
        )
        let resolved = try AgentIntegrationProbeWire.requireType(
            "approval.result",
            in: controller.exchange(AgentIntegrationProbeWire.resolve(
                epoch: epoch,
                runID: runID,
                requestID: requestID
            ))
        )
        #expect(ApprovalControllerConnection.brokerTerminal(fromDetail: resolved) == .resolved(.allowOnce))
        let waited = try AgentIntegrationProbeWire.requireType("approval.result", in: requester.exchange(
            AgentIntegrationApprovalWire.wait(epoch: epoch, runID: runID, requestID: requestID, maximumWaitMilliseconds: 0)
        ))
        #expect(ApprovalControllerConnection.brokerTerminal(fromDetail: waited) == .resolved(.allowOnce))
    }

    @Test func aRequesterCannotResolveItsOwnPendingRequest() throws {
        let service = try RustApprovalService(maximumRecords: 8)
        let runID = UUID()
        let requestID = UUID()
        let requester = try service.requesterSession(runID: runID)
        let epoch = try completeHello(on: requester)
        let submitted = try AgentIntegrationProbeWire.requireType("approval.result", in: requester.exchange(
            AgentIntegrationProbeWire.submit(epoch: epoch, runID: runID, requestID: requestID)
        ))
        try #require(try state(of: submitted)["status"] as? String == "pending")

        let response = try AgentIntegrationProbeWire.response(requester.exchange(
            AgentIntegrationProbeWire.resolve(
                epoch: epoch,
                runID: runID,
                requestID: requestID
            )
        ))
        #expect(response["type"] as? String == "error")
        let body = try #require(response["body"] as? [String: Any])
        #expect(body["code"] as? String == "unauthorized")
        let controller = try service.controllerSession()
        try #require(try completeHello(on: controller) == epoch)
        let untouched = try get(on: controller, epoch: epoch, runID: runID, requestID: requestID)
        #expect(try state(of: untouched)["status"] as? String == "pending")
    }

    @Test func requesterCannotSubmitForAnotherRun() throws {
        let service = try RustApprovalService(maximumRecords: 8)
        let requester = try service.requesterSession(runID: UUID())
        let epoch = try completeHello(on: requester)
        let response = try AgentIntegrationProbeWire.response(requester.exchange(
            AgentIntegrationProbeWire.submit(
                epoch: epoch,
                runID: UUID(),
                requestID: UUID()
            )
        ))
        #expect(response["type"] as? String == "error")
        let body = try #require(response["body"] as? [String: Any])
        #expect(body["code"] as? String == "unauthorized")
        let controller = try service.controllerSession()
        try #require(try completeHello(on: controller) == epoch)
        let snapshot = try AgentIntegrationProbeWire.requireType(
            "approval.snapshot.result",
            in: controller.exchange(AgentIntegrationApprovalWire.snapshot(epoch: epoch))
        )
        let snapshotBody = try #require(snapshot["body"] as? [String: Any])
        let requests = try #require(snapshotBody["requests"] as? [[String: Any]])
        #expect(requests.isEmpty)
    }

    @Test func malformedDiscreteMessageFailsWithoutResponse() throws {
        let service = try RustApprovalService(maximumRecords: 8)
        let requester = try service.requesterSession(runID: UUID())
        let error = #expect(throws: AgentIntegrationError.self) {
            try requester.exchange(Data("not-json".utf8))
        }
        guard case let .rustFailure(status)? = error else {
            Issue.record("Expected the Rust JSON decode status")
            return
        }
        #expect(status == Int32(WEIR_APPROVAL_INVALID_JSON.rawValue))
        let epoch = try completeHello(on: requester)
        let controller = try service.controllerSession()
        #expect(try completeHello(on: controller) == epoch)
    }

    @Test func previousServiceEpochCannotResolveAfterRestart() throws {
        let previousService = try RustApprovalService(maximumRecords: 8)
        let previousController = try previousService.controllerSession()
        let previousEpoch = try completeHello(on: previousController)

        let currentService = try RustApprovalService(maximumRecords: 8)
        let currentController = try currentService.controllerSession()
        let currentEpoch = try completeHello(on: currentController)
        try #require(currentEpoch != previousEpoch)
        let run = UUID()
        let request = UUID()
        let requester = try currentService.requesterSession(runID: run)
        try #require(try completeHello(on: requester) == currentEpoch)
        let submitted = try AgentIntegrationProbeWire.requireType("approval.result", in: requester.exchange(
            AgentIntegrationProbeWire.submit(epoch: currentEpoch, runID: run, requestID: request)
        ))
        try #require(try state(of: submitted)["status"] as? String == "pending")

        let response = try AgentIntegrationProbeWire.requireType("error", in: currentController.exchange(
            AgentIntegrationProbeWire.resolve(epoch: previousEpoch, runID: run, requestID: request)
        ))
        let body = try #require(response["body"] as? [String: Any])
        #expect(body["code"] as? String == "epoch_mismatch")
        let untouched = try get(on: currentController, epoch: currentEpoch, runID: run, requestID: request)
        #expect(try state(of: untouched)["status"] as? String == "pending")

        let accepted = try AgentIntegrationProbeWire.requireType("approval.result", in: currentController.exchange(
            AgentIntegrationProbeWire.resolve(epoch: currentEpoch, runID: run, requestID: request)
        ))
        #expect(ApprovalControllerConnection.brokerTerminal(fromDetail: accepted) == .resolved(.allowOnce))
    }

    /// The broker reads `body.questions` and `body.decision.answers` by name,
    /// so a renamed key would silently drop the question card or the answer.
    @Test func approvalWire_questionsAndAnswers_useTheBrokerKeys() throws {
        let expectedQuestions: [[String: Any]] = [
            ["prompt": "Which color?", "options": [["label": "Red", "description": "warm"]], "multi_select": false],
            ["prompt": "Which sizes?", "header": "Size", "options": [["label": "Small"], ["label": "Large"]], "multi_select": true]
        ]
        let expectedAnswers = ["Which color?": "Red", "Which sizes?": "Small, Large"]
        let submission = AgentIntegrationApprovalSubmission(
            runID: UUID(),
            requestID: UUID(),
            provider: "claude",
            sessionID: nil,
            operationID: nil,
            toolName: "AskUserQuestion",
            summary: "Which color?",
            input: [String: Any](),
            questions: expectedQuestions,
            timeoutMilliseconds: 1000
        )
        let submitted = try AgentIntegrationApprovalWire.object(from: AgentIntegrationApprovalWire.submit(
            epoch: UUID(),
            submission: submission
        ))
        let submitBody = try #require(submitted["body"] as? [String: Any])
        let questions = try #require(submitBody["questions"] as? [[String: Any]])
        let written = try JSONSerialization.data(withJSONObject: questions, options: [.sortedKeys])
        #expect(try written == (JSONSerialization.data(withJSONObject: expectedQuestions, options: [.sortedKeys])))

        let answered = try AgentIntegrationApprovalWire.object(from: AgentIntegrationApprovalWire.resolve(
            epoch: UUID(),
            runID: submission.runID,
            requestID: submission.requestID,
            decision: "answer",
            answers: expectedAnswers
        ))
        let answerBody = try #require(answered["body"] as? [String: Any])
        let answerDecision = try #require(answerBody["decision"] as? [String: Any])
        #expect(answerDecision["decision"] as? String == "answer")
        let answers = try #require(answerDecision["answers"] as? [String: String])
        #expect(answers == expectedAnswers)

        let denied = try AgentIntegrationApprovalWire.object(from: AgentIntegrationApprovalWire.resolve(
            epoch: UUID(),
            runID: submission.runID,
            requestID: submission.requestID,
            decision: "deny"
        ))
        let denyBody = try #require(denied["body"] as? [String: Any])
        let denyDecision = try #require(denyBody["decision"] as? [String: Any])
        #expect(denyDecision["decision"] as? String == "deny")
        #expect(denyDecision["answers"] == nil)
    }

    @Test func fitsDecisionLimit_countsEncodedBytesNotCharacters() {
        #expect(ApprovalResolution.answer(["Which color?": "Red"]).fitsDecisionLimit)
        #expect(ApprovalResolution.answer(["q": String(repeating: "a", count: 8000)]).fitsDecisionLimit)
        // 3,000 characters, but 9,000 UTF-8 bytes on the wire.
        #expect(!ApprovalResolution.answer(["q": String(repeating: "あ", count: 3000)]).fitsDecisionLimit)
        #expect(ApprovalResolution.delegate.fitsDecisionLimit)
    }

    /// The card refuses to send an answer `fitsDecisionLimit` rejects, so its
    /// limit has to be the broker's to the byte: a smaller one blocks answers
    /// the broker would take, and a larger one lets through answers that can
    /// only fail.
    @Test func answerAtTheDecisionLimit_isWhatTheBrokerAccepts() throws {
        let service = try RustApprovalService(maximumRecords: 8)
        let runID = UUID()
        let requestID = UUID()
        let requester = try service.requesterSession(runID: runID)
        let controller = try service.controllerSession()
        let epoch = try completeHello(on: requester)
        _ = try completeHello(on: controller)
        _ = try AgentIntegrationProbeWire.requireType(
            "approval.result",
            in: requester.exchange(AgentIntegrationProbeWire.submit(epoch: epoch, runID: runID, requestID: requestID))
        )

        // ASCII without `/` encodes the same in Foundation and serde, so the
        // padding lands the decision exactly on the limit.
        let emptyDecision = try JSONSerialization.data(withJSONObject: AgentIntegrationApprovalWire.decisionBody(
            decision: "answer",
            answers: ["q": ""]
        ))
        let padding = ApprovalResolution.maximumEncodedBytes - emptyDecision.count
        let atLimit = ApprovalResolution.answer(["q": String(repeating: "a", count: padding)])
        let overLimit = ApprovalResolution.answer(["q": String(repeating: "a", count: padding + 1)])
        #expect(atLimit.fitsDecisionLimit)
        #expect(!overLimit.fitsDecisionLimit)

        func resolve(_ resolution: ApprovalResolution) throws -> [String: Any] {
            try AgentIntegrationProbeWire.response(controller.exchange(AgentIntegrationApprovalWire.resolve(
                epoch: epoch,
                runID: runID,
                requestID: requestID,
                decision: resolution.wireDecision,
                answers: resolution.answers
            )))
        }
        let refused = try resolve(overLimit)
        #expect(refused["type"] as? String == "error")
        let refusal = try #require(refused["body"] as? [String: Any])
        #expect(refusal["code"] as? String == "invalid_request")
        let pending = try get(on: controller, epoch: epoch, runID: runID, requestID: requestID)
        #expect(try state(of: pending)["status"] as? String == "pending")
        let accepted = try resolve(atLimit)
        #expect(ApprovalControllerConnection.brokerTerminal(fromDetail: accepted) == .resolved(atLimit))
        let confirmed = try get(on: controller, epoch: epoch, runID: runID, requestID: requestID)
        #expect(ApprovalControllerConnection.brokerTerminal(fromDetail: confirmed) == .resolved(atLimit))
    }

    private func get(on session: RustApprovalSession, epoch: UUID, runID: UUID, requestID: UUID) throws -> [String: Any] {
        try AgentIntegrationProbeWire.requireType("approval.result", in: session.exchange(
            AgentIntegrationApprovalWire.get(epoch: epoch, runID: runID, requestID: requestID)
        ))
    }

    private func state(of response: [String: Any]) throws -> [String: Any] {
        try #require(response["type"] as? String == "approval.result")
        let body = try #require(response["body"] as? [String: Any])
        return try #require(body["state"] as? [String: Any])
    }

    private func completeHello(on session: RustApprovalSession) throws -> UUID {
        let (hello, _) = try AgentIntegrationProbeWire.hello()
        return try AgentIntegrationProbeWire.epoch(
            from: AgentIntegrationProbeWire.response(session.exchange(hello))
        )
    }
}
