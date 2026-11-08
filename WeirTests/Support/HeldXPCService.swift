// HeldXPCService.swift
// Weir — an in-process approval service that holds its replies.

import Foundation
@testable import Weir

/// An anonymous XPC listener in the test's own process that speaks the
/// approval service's protocol and never answers what it holds, so a test
/// can stop a client in the middle of a blocking call and see what ends it.
///
/// `.everything` holds the session's open itself. `.afterOpening` opens a
/// controller session as the bundled service would, with the test host's
/// bundled artifact and a hello, answers the first snapshot with no
/// requests, and holds every exchange after that: the subscription.
///
/// `@unchecked Sendable`: `held` is read and written only under `lock`, and
/// the listener is set up once in `init`.
final class HeldXPCService: NSObject, NSXPCListenerDelegate, AgentIntegrationXPCProtocol, @unchecked Sendable {
    enum Holding {
        case everything
        case afterOpening(AgentIntegrationServiceArtifact)
    }

    private let holding: Holding
    private let listener = NSXPCListener.anonymous()
    private let lock = NSLock()
    private var held: [(Data?, NSError?) -> Void] = []
    private let (heldEvents, heldEvent) = AsyncStream.makeStream(of: Void.self)

    /// Waits for the held call to reach the service, or test cancellation.
    func waitUntilHeld(_ count: Int = 1) async {
        guard heldCount < count else { return }
        for await _ in heldEvents where heldCount >= count {
            return
        }
    }

    init(holding: Holding) {
        self.holding = holding
        super.init()
        listener.delegate = self
        listener.resume()
    }

    deinit {
        listener.invalidate()
        heldEvent.finish()
    }

    /// How many calls are waiting for a reply.
    var heldCount: Int {
        lock.withLock { held.count }
    }

    /// A client on a new connection to this listener.
    func client(
        timeoutSeconds: Int = 70,
        waitForReply: @escaping @Sendable (DispatchSemaphore, Int) -> DispatchTimeoutResult = {
            $0.wait(timeout: .now() + .seconds($1))
        }
    ) throws -> AgentIntegrationXPCClient {
        try AgentIntegrationXPCClient(
            connection: NSXPCConnection(listenerEndpoint: listener.endpoint),
            timeoutSeconds: timeoutSeconds,
            waitForReply: waitForReply
        )
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: (any AgentIntegrationXPCProtocol).self)
        connection.exportedObject = self
        connection.activate()
        return true
    }

    func openSession(withReply reply: @escaping (Data?, NSError?) -> Void) {
        guard case let .afterOpening(artifact) = holding else {
            hold(reply)
            return
        }
        let bootstrap = AgentIntegrationSessionBootstrap(
            role: .controller,
            runID: nil,
            serviceProcessID: ProcessInfo.processInfo.processIdentifier,
            serviceArtifact: artifact
        )
        reply(try? JSONEncoder().encode(bootstrap), nil)
    }

    func exchange(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        guard case .afterOpening = holding else {
            hold(reply)
            return
        }
        let answer: [String: Any]? = switch (try? AgentIntegrationApprovalWire.object(from: request))?["type"] as? String {
        case "hello":
            ["type": "hello.result", "service_epoch": UUID().uuidString]
        case "approval.snapshot":
            ["type": "approval.snapshot.result", "body": ["sequence": 0, "requests": [] as [Any]]]
        default:
            nil
        }
        guard let answer else {
            hold(reply)
            return
        }
        reply(try? JSONSerialization.data(withJSONObject: answer), nil)
    }

    private func hold(_ reply: @escaping (Data?, NSError?) -> Void) {
        lock.withLock { held.append(reply) }
        heldEvent.yield(())
    }
}

/// Holds one call before it consumes its reply signal. The test checks the
/// signal synchronously after invalidation, before allowing the thread to
/// resume, so CI scheduling cannot enter the one-second release contract.
/// `@unchecked Sendable`: mutable values use `Recorded`'s lock; the
/// semaphores and stream continuation support concurrent use.
final class HeldReplyWait: @unchecked Sendable {
    private let callNumber: Int
    private let calls = Recorded(0)
    private let resume = DispatchSemaphore(value: 0)
    private let result = Recorded<DispatchTimeoutResult>(.timedOut)
    private let (waitingEvents, waitingEvent) = AsyncStream.makeStream(of: Void.self)

    /// Waits until the chosen call reaches the wait, or test cancellation.
    func waitUntilWaiting() async {
        for await _ in waitingEvents {}
    }

    init(callNumber: Int = 1) {
        self.callNumber = callNumber
    }

    private let held = Recorded<DispatchSemaphore?>(nil)

    func wait(_ semaphore: DispatchSemaphore, seconds: Int) -> DispatchTimeoutResult {
        var ordinal = 0
        calls.update {
            $0 += 1
            ordinal = $0
        }
        guard ordinal == callNumber else {
            return semaphore.wait(timeout: .now() + .seconds(seconds))
        }
        held.value = semaphore
        waitingEvent.finish()
        guard resume.wait(timeout: .now() + .seconds(seconds)) == .success else { return .timedOut }
        return result.value
    }

    /// Whether invalidation has already signaled, with no scheduling or
    /// elapsed-time allowance. Releases the held thread even on failure.
    func releaseAfterCheckingSignal() -> Bool {
        let outcome = held.value?.wait(timeout: .now()) ?? .timedOut
        result.value = outcome
        resume.signal()
        return outcome == .success
    }
}

/// Holds a caller after its reply signal arrived, so invalidation competes
/// with a completed reply before the client reads the result.
/// `@unchecked Sendable`: the stream and semaphore support concurrent use.
final class HeldCompletedReplyWait: @unchecked Sendable {
    private let (events, ready) = AsyncStream.makeStream(of: Void.self)
    private let resume = DispatchSemaphore(value: 0)

    func waitUntilReady() async {
        for await _ in events {}
    }

    func wait(_ semaphore: DispatchSemaphore, seconds: Int) -> DispatchTimeoutResult {
        let result = semaphore.wait(timeout: .now() + .seconds(seconds))
        ready.finish()
        guard resume.wait(timeout: .now() + .seconds(seconds)) == .success else { return .timedOut }
        return result
    }

    func release() {
        resume.signal()
    }
}
