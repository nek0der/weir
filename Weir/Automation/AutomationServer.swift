// AutomationServer.swift
// Weir — the Unix socket of the verification channel: framing, the token,
// and the limits, off the main actor.

#if DEBUG && WEIR_AUTOMATION

    import Darwin
    import Foundation
    import OSLog

    private let log = Logger.weir("automation")

    /// Accepts connections on one socket and turns each line into a request for
    /// `handle`. Never touches app state itself: `handle` is the main actor's.
    ///
    /// `@unchecked Sendable` because every stored property is read and written
    /// only on `queue`, which the dispatch sources and every method hop to;
    /// the lock-free sharing the compiler cannot see is that confinement.
    final class AutomationServer: @unchecked Sendable {
        typealias Handler = @Sendable (AutomationRequest) async -> AutomationReply

        private final class Connection {
            let fd: Int32
            var source: (any DispatchSourceRead)?
            var buffer = Data()
            var isAuthenticated = false
            var tasks: [UUID: Task<Void, Never>] = [:]

            init(fd: Int32) {
                self.fd = fd
            }
        }

        private let queue = DispatchQueue(label: "com.nekoder.weir.automation")
        private let token: String
        private let handle: Handler
        private var listenFD: Int32 = -1
        private var listenSource: (any DispatchSourceRead)?
        private var connections: [Int32: Connection] = [:]

        init(token: String, handle: @escaping Handler) {
            self.token = token
            self.handle = handle
        }

        /// Binds `path` and starts accepting. The socket is made 0600 before it
        /// listens, so no other user can connect in between.
        func start(at path: String) throws {
            try queue.sync {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { throw Self.posixError("socket") }
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                let capacity = MemoryLayout.size(ofValue: address.sun_path)
                guard path.utf8.count < capacity else {
                    close(fd)
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
                }
                withUnsafeMutableBytes(of: &address.sun_path) { raw in
                    raw.copyBytes(from: path.utf8)
                    raw[path.utf8.count] = 0
                }
                unlink(path)
                let bound = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard bound == 0 else {
                    close(fd)
                    throw Self.posixError("bind")
                }
                chmod(path, 0o600)
                guard listen(fd, 8) == 0 else {
                    close(fd)
                    throw Self.posixError("listen")
                }
                listenFD = fd
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.acceptConnection() }
                source.setCancelHandler { close(fd) }
                source.resume()
                listenSource = source
            }
        }

        /// Closes every connection, canceling their requests, and the socket.
        func stop() {
            queue.sync {
                for fd in Array(connections.keys) {
                    drop(fd)
                }
                listenSource?.cancel()
                listenSource = nil
                listenFD = -1
            }
        }

        // MARK: - On `queue`

        private func acceptConnection() {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            guard connections.count < AutomationProtocol.maxConnections else {
                log.error("automation connection refused: too many open")
                close(fd)
                return
            }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            // A client that stops reading fills the socket's buffer, and a
            // write past it would hold `queue`, every other connection, and a
            // quit waiting in `stop()`. Past this the write fails and the
            // connection is dropped.
            var sendTimeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            let connection = Connection(fd: fd)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(fd) }
            // Closed once the source is done with it: closing first could hand
            // the number to the next connection while this source still reads.
            source.setCancelHandler { close(fd) }
            connection.source = source
            connections[fd] = connection
            source.resume()
        }

        private func read(_ fd: Int32) {
            guard let connection = connections[fd] else { return }
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.read(fd, &chunk, chunk.count)
            guard count > 0 else {
                drop(fd)
                return
            }
            connection.buffer.append(contentsOf: chunk[0..<count])
            while let newline = connection.buffer.firstIndex(of: 0x0A) {
                let line = connection.buffer[connection.buffer.startIndex..<newline]
                connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
                receive(Data(line), on: connection)
                guard connections[fd] != nil else { return }
            }
            if connection.buffer.count > AutomationProtocol.maxMessageBytes {
                log.error("automation connection closed: a line past the limit")
                drop(fd)
            }
        }

        private func receive(_ line: Data, on connection: Connection) {
            guard line.count <= AutomationProtocol.maxMessageBytes else {
                drop(connection.fd)
                return
            }
            let request: AutomationRequest
            do {
                request = try JSONDecoder().decode(AutomationRequest.self, from: line)
            } catch {
                // The ID is read on its own so the caller can match the reply,
                // and the decoder's words say which field was wrong (an unknown
                // layer, a misspelled operation).
                let id = (try? JSONDecoder().decode(RequestID.self, from: line))?.id ?? ""
                send(.failed(id, "the line is not a request: \(Self.describe(error))"), to: connection)
                // Before hello nothing else is answered, and a caller that
                // cannot frame a request has no business staying connected.
                if !connection.isAuthenticated {
                    drop(connection.fd)
                }
                return
            }
            guard connection.isAuthenticated else {
                authenticate(request, on: connection)
                return
            }
            let taskID = UUID()
            let handle = handle
            let fd = connection.fd
            let queue = queue
            connection.tasks[taskID] = Task {
                let reply = await handle(request)
                queue.async { [weak self] in
                    // The task's own ID, not the descriptor, says the
                    // connection is still the one that asked: a closed
                    // descriptor's number goes to the next connection.
                    guard let self, let connection = self.connections[fd],
                          connection.tasks.removeValue(forKey: taskID) != nil
                    else { return }
                    self.send(reply, to: connection)
                }
            }
        }

        /// The one field read from a line that is not a whole request.
        private struct RequestID: Decodable {
            let id: String
        }

        private static func describe(_ error: any Error) -> String {
            guard let error = error as? DecodingError else { return error.localizedDescription }
            switch error {
            case let .dataCorrupted(context), let .keyNotFound(_, context), let .typeMismatch(_, context), let .valueNotFound(_, context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
            @unknown default:
                return error.localizedDescription
            }
        }

        private func authenticate(_ request: AutomationRequest, on connection: Connection) {
            let isHello = request.op == .hello && request.protocol == AutomationProtocol.marker
            guard isHello, let offered = request.token, Self.constantTimeEqual(offered, token) else {
                send(.failed(request.id, "the first request must be hello with this run's token"), to: connection)
                drop(connection.fd)
                return
            }
            connection.isAuthenticated = true
            send(AutomationReply(id: request.id, status: .done), to: connection)
        }

        private func send(_ reply: AutomationReply, to connection: Connection) {
            // A reply is plain values and always encodes; one that did not
            // would leave the caller waiting, so the connection goes instead.
            guard var data = try? JSONEncoder().encode(reply) else {
                drop(connection.fd)
                return
            }
            data.append(0x0A)
            let isWritten = data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                var offset = 0
                while offset < raw.count {
                    let written = write(connection.fd, base + offset, raw.count - offset)
                    guard written > 0 else { return false }
                    offset += written
                }
                return true
            }
            if !isWritten {
                drop(connection.fd)
            }
        }

        private func drop(_ fd: Int32) {
            guard let connection = connections.removeValue(forKey: fd) else { return }
            for task in connection.tasks.values {
                task.cancel()
            }
            connection.source?.cancel()
        }

        private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
            let left = Array(lhs.utf8)
            let right = Array(rhs.utf8)
            guard left.count == right.count else { return false }
            var difference: UInt8 = 0
            for (a, b) in zip(left, right) {
                difference |= a ^ b
            }
            return difference == 0
        }

        private static func posixError(_ call: String) -> NSError {
            NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(call) failed"]
            )
        }
    }

#endif
