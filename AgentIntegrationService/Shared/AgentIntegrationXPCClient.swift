// AgentIntegrationXPCClient.swift
// Weir — authenticated client for one role-specific integration endpoint.

import Foundation

/// `@unchecked Sendable` because `NSXPCConnection` is not marked `Sendable`.
/// It is safe: apart from `isInvalidated` and the pending calls, which are accessed only
/// under `lock`, the client holds only constants, `NSXPCConnection` may be
/// messaged and invalidated from any thread, and each call keeps its result
/// in a box of its own behind a lock. That lets the app block on a call off
/// the cooperative pool and invalidate it from a cancellation handler.
final class AgentIntegrationXPCClient: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let timeoutSeconds: Int
    /// The blocking wait, injected by tests to inspect a release before the
    /// waiting thread resumes. Production uses the semaphore's deadline.
    private let waitForReply: @Sendable (DispatchSemaphore, Int) -> DispatchTimeoutResult
    private let lock = NSLock()
    /// Whether invalidation has closed admission to new calls. Protected by
    /// `lock` together with the calls it must release.
    private var isInvalidated = false
    /// Calls registered before invalidation, removed on completion or timeout.
    private var pending: [UUID: AgentIntegrationResultBox<Data>] = [:]

    convenience init(role: AgentIntegrationRole, timeoutSeconds: Int = 5) throws {
        let machService = switch role {
        case .requester: AgentIntegrationConfiguration.requesterMachService
        case .controller: AgentIntegrationConfiguration.controllerMachService
        }
        let connection = NSXPCConnection(machServiceName: machService, options: [])
        try connection.setCodeSigningRequirement(AgentIntegrationSigning.requirement(
            peerIdentifiers: [AgentIntegrationConfiguration.serviceIdentifier]
        ))
        try self.init(connection: connection, timeoutSeconds: timeoutSeconds)
    }

    /// A client on a connection whose peer the caller has already made
    /// sure of: `init(role:)` requires the service's signature, and a test
    /// connects to an anonymous listener in its own process.
    init(
        connection: NSXPCConnection,
        timeoutSeconds: Int = 5,
        waitForReply: @escaping @Sendable (DispatchSemaphore, Int) -> DispatchTimeoutResult = {
            $0.wait(timeout: .now() + .seconds($1))
        }
    ) throws {
        guard timeoutSeconds > 0 else {
            throw AgentIntegrationError.invalidArguments("The XPC timeout must be positive.")
        }
        connection.remoteObjectInterface = NSXPCInterface(with: (any AgentIntegrationXPCProtocol).self)
        connection.activate()
        self.connection = connection
        self.timeoutSeconds = timeoutSeconds
        self.waitForReply = waitForReply
    }

    deinit {
        connection.invalidate()
    }

    /// Ends the connection and signals every pending call before returning.
    /// Later calls fail locally without asking XPC for a proxy. Neither path
    /// waits for XPC's error queue, which may be delayed under load.
    func invalidate() {
        lock.withLock {
            isInvalidated = true
            // Signaling inside this lock also makes concurrent invalidations
            // wait until every admitted call has its completion signal.
            for call in pending.values {
                call.set(.failure(AgentIntegrationError.requestFailed("The connection was invalidated.")))
            }
            pending.removeAll()
        }
        connection.invalidate()
    }

    func openSession() throws -> AgentIntegrationSessionBootstrap {
        let response = try call { proxy, reply in
            proxy.openSession(withReply: reply)
        }
        return try JSONDecoder().decode(AgentIntegrationSessionBootstrap.self, from: response)
    }

    func exchange(_ request: Data, timeoutSeconds: Int? = nil) throws -> Data {
        guard request.count <= AgentIntegrationConfiguration.maximumXPCRequestBytes else {
            throw AgentIntegrationError.invalidArguments("The request exceeds the XPC size limit.")
        }
        let timeoutSeconds = timeoutSeconds ?? self.timeoutSeconds
        guard timeoutSeconds > 0 else {
            throw AgentIntegrationError.invalidArguments("The XPC timeout must be positive.")
        }
        let response = try call(timeoutSeconds: timeoutSeconds) { proxy, reply in
            proxy.exchange(request, withReply: reply)
        }
        guard response.count <= AgentIntegrationConfiguration.maximumXPCResponseBytes else {
            throw AgentIntegrationError.invalidResponse
        }
        return response
    }

    private func call(
        timeoutSeconds: Int? = nil,
        _ body: (any AgentIntegrationXPCProtocol, @escaping (Data?, NSError?) -> Void) -> Void
    ) throws -> Data {
        let id = UUID()
        let result = AgentIntegrationResultBox<Data>()
        // Registration and invalidation share a lock, so a call cannot enter
        // between the invalidation check and the snapshot of pending calls.
        let wasRegistered = lock.withLock {
            guard !isInvalidated else { return false }
            pending[id] = result
            return true
        }
        guard wasRegistered else {
            throw AgentIntegrationError.requestFailed("The connection was invalidated.")
        }
        defer { _ = lock.withLock { pending.removeValue(forKey: id) } }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            result.set(.failure(AgentIntegrationError.requestFailed(error.localizedDescription)))
        }) as? any AgentIntegrationXPCProtocol else {
            throw AgentIntegrationError.invalidResponse
        }
        body(proxy) { data, error in
            if let error {
                result.set(.failure(AgentIntegrationError.requestFailed(error.localizedDescription)))
            } else if let data {
                result.set(.success(data))
            } else {
                result.set(.failure(AgentIntegrationError.invalidResponse))
            }
        }
        let timeoutSeconds = timeoutSeconds ?? self.timeoutSeconds
        guard waitForReply(result.semaphore, timeoutSeconds) == .success else {
            throw AgentIntegrationError.timeout
        }
        return try result.get()
    }
}

private final class AgentIntegrationResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    /// The first completion; later XPC replies cannot replace invalidation.
    private var result: Result<Value, any Error>?
    let semaphore = DispatchSemaphore(value: 0)

    func set(_ result: Result<Value, any Error>) {
        lock.withLock {
            guard self.result == nil else { return }
            self.result = result
            semaphore.signal()
        }
    }

    func get() throws -> Value {
        try lock.withLock {
            guard let result else { throw AgentIntegrationError.invalidResponse }
            return try result.get()
        }
    }
}
