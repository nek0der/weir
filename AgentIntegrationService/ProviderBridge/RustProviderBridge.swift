// RustProviderBridge.swift
// Weir — ownership-safe Swift wrapper around the provider translation C ABI.
//
// Lives outside `Shared/` because the probe executables compile `Shared/`
// without linking the Rust bridge; only the Hook Helper and the app do.

import Dispatch
import Foundation
import WeirRustBridge

enum RustProviderBridge {
    /// Translates a provider hook payload into the neutral approval request,
    /// returned as the JSON document the Rust model serializes. `nil` means
    /// the payload is valid but is not a permission request.
    static func approvalRequest(provider: String, payload: Data) throws -> Data? {
        try call(provider: provider, input: payload, notApproval: true) { pointers in
            weir_provider_approval_request_v1(
                pointers.provider, pointers.providerCount,
                pointers.input, pointers.inputCount,
                pointers.out, pointers.outCount
            )
        }
    }

    /// Renders a decision with the request it answers. Only an answer needs
    /// the request; it echoes the provider's tool input back with the answers.
    static func approvalOutput(provider: String, requestJSON: Data, decisionJSON: Data) throws -> Data? {
        try RustBytes.withBytes(requestJSON) { requestPointer, requestCount in
            try call(provider: provider, input: decisionJSON, notApproval: false) { pointers in
                weir_provider_approval_output_v2(
                    pointers.provider, pointers.providerCount,
                    requestPointer, requestCount,
                    pointers.input, pointers.inputCount,
                    pointers.out, pointers.outCount
                )
            }
        }
    }

    /// Returns the names `provider`'s process has, as its descriptor in the
    /// Rust registry lists them, so a process search follows the descriptor
    /// rather than a copy of it. The set is empty for a provider this build
    /// does not have.
    static func processNames(provider: String) throws -> Set<String> {
        guard let descriptor = try descriptor(provider: provider) else { return [] }
        return Set(descriptor.processNames)
    }

    /// The capabilities `provider`'s descriptor declares, in their Rust
    /// names (`question_ends_with_turn`), so the helper branches on what a
    /// provider does rather than on its id. Empty for a provider this build
    /// does not have, and when the registry cannot be read: a capability
    /// assumed would act on a request the provider does not send that way.
    static func capabilities(provider: String) -> Set<String> {
        // `try?`: no registry reads as no capability, the default above.
        guard let descriptor = try? descriptor(provider: provider) else { return [] }
        return Set(descriptor.capabilities)
    }

    /// `provider`'s descriptor as the Rust registry reports it, or `nil`
    /// when this build does not have the provider.
    private static func descriptor(provider: String) throws -> AgentProviderDescriptor? {
        let output = RustBytes.call { out, outCount in
            weir_projection_providers_v1(out, outCount)
        }
        guard output.status == Int32(WEIR_PROJECTION_OK.rawValue), let registry = output.body else {
            throw AgentIntegrationError.rustFailure(output.status)
        }
        do {
            return try AgentProviderDescriptor.descriptor(provider, in: registry)
        } catch {
            throw AgentIntegrationError.invalidResponse
        }
    }

    /// A turn that failed, as the provider's crate reads it from a line of its
    /// transcript.
    struct TurnFailureReport {
        /// The hook payload to report.
        var payload: [String: Any]
        /// When the line says it was written; `nil` when it does not say.
        let writtenAt: Date?
        /// The message that names when a usage limit resets, for the host to
        /// read in the time zone the provider ran in.
        let usageLimitMessage: String?
        /// The payload key for that reset.
        let messageResetKey: String
    }

    /// The report for `line` when it is a turn that failed, else `nil`. A line
    /// with no time of its own was written no later than `readAt`.
    static func turnFailureReport(
        provider: String,
        line: Data,
        transcriptPath: String,
        sessionID: String,
        readAt: Date
    ) throws -> TurnFailureReport? {
        let path = Array(transcriptPath.utf8)
        let session = Array(sessionID.utf8)
        let body = try call(provider: provider, input: line, notApproval: false) { pointers in
            weir_provider_turn_failure_report_v1(
                pointers.provider, pointers.providerCount,
                pointers.input, pointers.inputCount,
                path, path.count,
                session, session.count,
                UInt64(max(0, readAt.timeIntervalSince1970)),
                pointers.out, pointers.outCount
            )
        }
        guard let body else { throw AgentIntegrationError.invalidResponse }
        let object = try JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed)
        if object is NSNull {
            return nil
        }
        guard let report = object as? [String: Any],
              let payload = report["payload"] as? [String: Any],
              let messageResetKey = report["message_reset_key"] as? String
        else { throw AgentIntegrationError.invalidResponse }
        return TurnFailureReport(
            payload: payload,
            writtenAt: (report["written_at"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            usageLimitMessage: report["usage_limit_message"] as? String,
            messageResetKey: messageResetKey
        )
    }

    /// The question turn `payload` names, or `nil` when it names none.
    static func questionTurn(provider: String, payload: Data) throws -> AgentQuestionTurn? {
        let body = try call(provider: provider, input: payload, notApproval: false) { pointers in
            weir_provider_question_turn_v1(
                pointers.provider, pointers.providerCount,
                pointers.input, pointers.inputCount,
                pointers.out, pointers.outCount
            )
        }
        guard let body else { throw AgentIntegrationError.invalidResponse }
        return try JSONDecoder().decode(AgentQuestionTurn?.self, from: body)
    }

    /// Which hook entry point `runHook` invokes.
    enum HookKind {
        case lifecycle
        case worktree
        case invocation

        /// The `WEIR_HOOK_KIND_*` constant the C ABI expects.
        var abiValue: UInt32 {
            switch self {
            case .lifecycle: UInt32(WEIR_HOOK_KIND_LIFECYCLE)
            case .worktree: UInt32(WEIR_HOOK_KIND_WORKTREE)
            case .invocation: UInt32(WEIR_HOOK_KIND_INVOCATION)
            }
        }
    }

    /// Runs one lifecycle or worktree hook call in-process. `environment` is
    /// what the hook runtime reads the shim's variables from, so a test can
    /// point it at a scratch directory. `observationClock` supplies this
    /// boot's monotonic nanoseconds and can be fixed by a test. Never opens
    /// the approval service.
    static func runHook(
        provider: String,
        kind: HookKind,
        payload: Data,
        environment: [String: String],
        observationClock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) throws -> RustHookOutcome {
        var environment = environment
        environment["WEIR_HOOK_OBSERVED_ORDER"] = String(observationClock())
        let environmentJSON = try JSONEncoder().encode(environment)
        let body = try RustBytes.withBytes(environmentJSON) { environmentPointer, environmentCount in
            try call(provider: provider, input: payload, notApproval: false) { pointers in
                weir_hook_run_v1(
                    pointers.provider, pointers.providerCount,
                    kind.abiValue,
                    pointers.input, pointers.inputCount,
                    environmentPointer, environmentCount,
                    pointers.out, pointers.outCount
                )
            }
        }
        guard let body, let outcome = try? JSONDecoder().decode(RustHookOutcome.self, from: body)
        else { throw AgentIntegrationError.invalidResponse }
        return outcome
    }

    /// Appends `message` to the hook log at `path` through the runtime's own
    /// log, which keeps the file private to the user, refuses a symlink at
    /// `path`, and sets a full log aside. `false` when the line could not be
    /// written there, or the bridge refused the input.
    static func logLine(_ message: String, to path: String) -> Bool {
        let pathBytes = Data(path.utf8)
        let messageBytes = Data(message.utf8)
        let status = RustBytes.withBytes(pathBytes) { pathPointer, pathCount in
            RustBytes.withBytes(messageBytes) { messagePointer, messageCount in
                weir_hook_log_line_v1(pathPointer, pathCount, messagePointer, messageCount)
            }
        }
        return status == Int32(WEIR_PROVIDER_OK.rawValue)
    }

    /// The input pointer-length pairs one ABI call receives, plus the output
    /// slots it fills.
    private struct Pointers {
        let provider: UnsafePointer<UInt8>?
        let providerCount: Int
        let input: UnsafePointer<UInt8>?
        let inputCount: Int
        let out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>
        let outCount: UnsafeMutablePointer<Int>
    }

    /// Runs one translation call and takes ownership of its output buffer.
    /// `notApproval` says whether `WEIR_PROVIDER_NOT_APPROVAL` is a valid
    /// outcome for this call (it is only for request translation).
    private static func call(
        provider: String,
        input: Data,
        notApproval: Bool,
        _ body: (Pointers) -> Int32
    ) throws -> Data? {
        let providerBytes = Data(provider.utf8)
        // Every pointer is scoped to the call: the buffers stay alive for the
        // duration of `body`, and the output is read only afterwards.
        let output = RustBytes.call { out, outCount in
            RustBytes.withBytes(providerBytes) { providerPointer, providerCount in
                RustBytes.withBytes(input) { inputPointer, inputCount in
                    body(Pointers(
                        provider: providerPointer,
                        providerCount: providerCount,
                        input: inputPointer,
                        inputCount: inputCount,
                        out: out,
                        outCount: outCount
                    ))
                }
            }
        }
        if let bytes = output.body {
            guard output.status == Int32(WEIR_PROVIDER_OK.rawValue) else {
                throw AgentIntegrationError.rustFailure(output.status)
            }
            return bytes
        }
        switch output.status {
        case Int32(WEIR_PROVIDER_OK.rawValue):
            // Success with an empty body: delegate.
            return nil
        case Int32(WEIR_PROVIDER_NOT_APPROVAL.rawValue) where notApproval:
            return nil
        default:
            throw AgentIntegrationError.rustFailure(output.status)
        }
    }
}

/// The outcome the hook runtime reports for one call, as the bridge
/// spells it (`weir_hook_run_v1`).
struct RustHookOutcome: Decodable, Equatable {
    /// What happened to the call. A word this build does not know is
    /// kept as it came, so a newer runtime's outcome still decodes and
    /// is only never taken for one of these.
    enum Kind: Equatable {
        case applied
        case notInWeir
        case rejected
        case unknownProvider
        case notRecorded
        case intercepted
        case other(String)

        init(_ word: String) {
            self = switch word {
            case "applied": .applied
            case "not_in_weir": .notInWeir
            case "rejected": .rejected
            case "unknown_provider": .unknownProvider
            case "not_recorded": .notRecorded
            case "intercepted": .intercepted
            default: .other(word)
            }
        }
    }

    let outcome: Kind
    let exitCode: Int32
    let message: String?
    /// What the hook prints, when the provider cancels a call that way.
    var stdout: String?

    private enum CodingKeys: String, CodingKey {
        case outcome
        case exitCode = "exit_code"
        case message
        case stdout
    }

    init(outcome: Kind, exitCode: Int32, message: String?, stdout: String? = nil) {
        self.outcome = outcome
        self.exitCode = exitCode
        self.message = message
        self.stdout = stdout
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try Kind(container.decode(String.self, forKey: .outcome))
        exitCode = try container.decode(Int32.self, forKey: .exitCode)
        // A value of another type reads as none, as the dictionary read
        // this replaced took it, rather than failing the whole outcome.
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        stdout = try? container.decodeIfPresent(String.self, forKey: .stdout)
    }
}

extension AgentQuestionTurnCompletion {
    /// The completion of the question `provider` asks in `payload`.
    init?(
        provider: String,
        payload: Data, environment: [String: String],
        requestedAt: UInt64? = nil, bootSessionID: String? = nil
    ) {
        guard let turn = try? RustProviderBridge.questionTurn(provider: provider, payload: payload) else {
            return nil
        }
        self.init(turn: turn, environment: environment, requestedAt: requestedAt, bootSessionID: bootSessionID)
    }

    /// Records that the turn `provider` ends in `payload` has ended.
    static func record(
        provider: String,
        payload: Data, environment: [String: String],
        completedAt: UInt64 = mach_absolute_time(), bootSessionID: String? = nil
    ) throws {
        guard let turn = try RustProviderBridge.questionTurn(provider: provider, payload: payload) else { return }
        try record(turn: turn, environment: environment, completedAt: completedAt, bootSessionID: bootSessionID)
    }
}
