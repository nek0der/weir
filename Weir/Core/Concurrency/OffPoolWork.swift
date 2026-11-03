// OffPoolWork.swift
// Weir — runs blocking work on a dispatch queue instead of the cooperative pool.

import Foundation

/// The way Weir awaits work that waits on another process or the kernel: a
/// semaphore on an XPC reply, a child process, a `sysctl`, a static code
/// check, a volume that may stop answering.
///
/// `Task.detached` and a `nonisolated` async function only move such work
/// off the main actor and onto Swift's cooperative pool, which has one
/// thread per core and never adds one for a thread that blocks. A few
/// blocked threads there are enough to stall every task in the app, the
/// review's and Git's included. A dispatch queue's worker that blocks is
/// replaced, up to GCD's thread limit, far above what these waits use, so
/// the pool keeps running.
///
/// Canceling the awaiting task does not stop `work`; a caller that blocks
/// for long ends the wait itself on cancellation, as the approval observer
/// does by invalidating its XPC connection.
enum OffPoolWork {
    static func run<Value: Sendable, Failure: Error>(
        qos: DispatchQoS.QoSClass = .utility,
        _ work: @escaping @Sendable () throws(Failure) -> Value
    ) async throws(Failure) -> Value {
        let result: Result<Value, Failure> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                do throws(Failure) {
                    try continuation.resume(returning: .success(work()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        return try result.get()
    }
}
