// AgentIntegrationXPCClient.swift
// Weir — authenticated client for one role-specific integration endpoint.

import Foundation

/// `@unchecked Sendable` because `NSXPCConnection` is not marked `Sendable`.
/// It is safe: apart from `isInvalidated`, which is read and written only
/// under `lock`, the client holds only constants, `NSXPCConnection` may be
/// messaged and invalidated from any thread, and each call keeps its result
/// in a box of its own behind a lock. That lets the app block on a call off
/// the cooperative pool and invalidate it from a cancellation handler.
final class AgentIntegrationXPCClient: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let timeoutSeconds: Int
    private let lock = NSLock()
    /// Set by `invalidate()`. We keep it ourselves rather than leave a later
    /// call to find out from XPC: XPC reports an invalidated connection by
    /// running the call's error handler on its own queue, which on a busy
    /// machine can take seconds.
    private var isInvalidated = false

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
    init(connection: NSXPCConnection, timeoutSeconds: Int = 5) throws {
        guard timeoutSeconds > 0 else {
            throw AgentIntegrationError.invalidArguments("The XPC timeout must be positive.")
        }
        connection.remoteObjectInterface = NSXPCInterface(with: (any AgentIntegrationXPCProtocol).self)
        connection.activate()
        self.connection = connection
        self.timeoutSeconds = timeoutSeconds
    }

    deinit {
        connection.invalidate()
    }

    /// Ends the connection. A call blocked waiting for its reply fails at
    /// once, because invalidating runs the error handler of every
    /// outstanding call. Any later call fails as soon as it is made, because
    /// it checks `isInvalidated` before it asks the connection for a proxy.
    func invalidate() {
        lock.withLock { isInvalidated = true }
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
        // A call that passes this check just before `invalidate()` still
        // ends at once: it is then outstanding, and XPC runs its error
        // handler.
        guard !lock.withLock({ isInvalidated }) else {
            throw AgentIntegrationError.requestFailed("The connection was invalidated.")
        }
        let result = AgentIntegrationResultBox<Data>()
        let semaphore = DispatchSemaphore(value: 0)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            result.set(.failure(AgentIntegrationError.requestFailed(error.localizedDescription)))
            semaphore.signal()
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
            semaphore.signal()
        }
        let timeoutSeconds = timeoutSeconds ?? self.timeoutSeconds
        guard semaphore.wait(timeout: .now() + .seconds(timeoutSeconds)) == .success else {
            throw AgentIntegrationError.timeout
        }
        return try result.get()
    }
}

private final class AgentIntegrationResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?

    func set(_ result: Result<Value, any Error>) {
        lock.withLock {
            guard self.result == nil else { return }
            self.result = result
        }
    }

    func get() throws -> Value {
        try lock.withLock {
            guard let result else { throw AgentIntegrationError.invalidResponse }
            return try result.get()
        }
    }
}
