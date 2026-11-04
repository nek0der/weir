// RustApprovalHost.swift
// Weir — ownership-safe Swift wrapper around the opaque approval C ABI.

import Foundation
import WeirRustBridge

/// The approval service every connection's session is made from.
///
/// `@unchecked Sendable` because the handle is the only state and never
/// changes after `init`, and the Rust service it names keeps its broker
/// behind a mutex (`ApprovalService`), so creating sessions and withdrawing
/// a run's requests are safe from any thread: the listener's queue creates
/// them, and a connection's invalidation handler withdraws on its own.
final class RustApprovalService: @unchecked Sendable {
    fileprivate let handle: OpaquePointer

    init(maximumRecords: Int) throws {
        guard let handle = weir_approval_service_create_v1(maximumRecords) else {
            throw AgentIntegrationError.rustFailure(Int32(WEIR_APPROVAL_INTERNAL.rawValue))
        }
        self.handle = handle
    }

    deinit {
        weir_approval_service_free_v1(handle)
    }

    func requesterSession(runID: UUID) throws -> RustApprovalSession {
        var bytes = runID.uuid
        let handle = withUnsafeBytes(of: &bytes) { buffer in
            weir_approval_session_create_requester_v1(
                self.handle,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                buffer.count
            )
        }
        // The 16 bytes come from a `UUID`, so the run ID cannot be what the
        // call refused: a null session is the bridge's own failure.
        guard let handle else {
            throw AgentIntegrationError.rustFailure(Int32(WEIR_APPROVAL_INTERNAL.rawValue))
        }
        return RustApprovalSession(service: self, handle: handle)
    }

    /// Withdraws every pending request of the requester run `runID`, whose
    /// connection is gone (`weir_approval_service_withdraw_requester_v1`).
    func withdrawRequester(runID: UUID) throws {
        var bytes = runID.uuid
        let status = withUnsafeBytes(of: &bytes) { buffer in
            weir_approval_service_withdraw_requester_v1(
                self.handle,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                buffer.count
            )
        }
        guard status == Int32(WEIR_APPROVAL_OK.rawValue) else {
            throw AgentIntegrationError.rustFailure(status)
        }
    }

    func controllerSession() throws -> RustApprovalSession {
        guard let handle = weir_approval_session_create_controller_v1(handle) else {
            throw AgentIntegrationError.rustFailure(Int32(WEIR_APPROVAL_INTERNAL.rawValue))
        }
        return RustApprovalSession(service: self, handle: handle)
    }
}

/// One connection's session.
///
/// `@unchecked Sendable` because both stored properties are immutable after
/// `init`, and the Rust session serializes its own use behind a mutex
/// (`weir_approval_session_exchange_v1`), so an exchange may run on any
/// thread, even beside another on the same session. The service exchanges
/// off the connection's queue for that reason (`PendingExchange`).
final class RustApprovalSession: @unchecked Sendable {
    // The Rust session retains the shared Arc, but keeping the Swift owner alive
    // also guarantees that no foreign handle is freed out of ABI order.
    private let service: RustApprovalService
    private let handle: OpaquePointer

    fileprivate init(service: RustApprovalService, handle: OpaquePointer) {
        self.service = service
        self.handle = handle
    }

    deinit {
        weir_approval_session_free_v1(handle)
    }

    func exchange(_ request: Data) throws -> Data {
        var output = weir_approval_bytes_v1(data: nil, len: 0)
        let status = RustBytes.withBytes(request) { pointer, count in
            weir_approval_session_exchange_v1(handle, pointer, count, &output)
        }
        // The size is checked before anything is copied.
        return try RustBytes.consume(output.data, count: output.len) { buffer in
            guard status == Int32(WEIR_APPROVAL_OK.rawValue) else {
                throw AgentIntegrationError.rustFailure(status)
            }
            guard output.len <= AgentIntegrationConfiguration.maximumXPCResponseBytes,
                  output.len == 0 || buffer != nil
            else { throw AgentIntegrationError.invalidResponse }
            return buffer.map { Data($0) } ?? Data()
        }
    }
}
