// main.swift
// Weir — signed PermissionRequest bridge to the authenticated approval
// service, and the process every lifecycle hook runs in.
//
// Separate subcommands: `permission-request <provider>`
// opens the approval service and waits for a decision. `hook <provider>
// [worktree | event <name> [worktree] | report <name> <typed fields>]` runs
// the Rust hook runtime in-process without opening an XPC connection, so
// lifecycle hooks remain independent of approval-service availability.
// `question-turn-ended [provider]` records a turn end without XPC so a
// terminal answer remains observable across controller startup
// delays; the provider defaults to Claude, whose settings call it bare.
// `watch-codex-failures <codex pid> <offset> <session> <rollout>` runs the watcher a Codex
// session start leaves (`CodexTurnFailureWatch`).
// `statusline <provider> [settings <relay command>]` is Claude Code's status
// line and the shim's setting for it (`StatusLineRelay`).

import Dispatch
import Foundation

// First, before anything here starts a thread: a thread takes the signal mask of
// the one that made it, and a SIGTERM that one thread still takes ends the
// process. Only a provider whose approval is withdrawn by one holds it; every
// other run ends on it as before. Reading the capability is a call into the
// Rust registry and a JSON parse on this thread, which start no thread. When
// that read fails, nothing is held: a SIGTERM ends this helper as it ends any
// other run, rather than withdrawing the request. We accept that
// rather than name a provider here, as the registry is compiled in and the
// request's own translation goes through the same one, so a read that fails
// leaves no request to withdraw in practice.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "permission-request",
   RustProviderBridge.capabilities(provider: CommandLine.arguments[2])
   .contains(ProviderCapabilityName.approvalWithdrawnBySignal)
{
    PendingTermination.hold()
}

/// Upper bound on one wait for a decision; the request's own timeout comes
/// from the provider crate and is shorter.
private let approvalWaitSeconds = 580
private let inputReadChunkBytes = 64 * 1024

/// Diagnostics go where `WEIR_HOOK_LOG` points, as the Rust runtime's own
/// lines do, so one file collects both sides of a failed hook. The providers
/// discard the stderr of a hook that exits 0, which is why stderr alone is
/// not enough. The value `1` keeps the old meaning of "print to stderr".
/// The runtime's log writes the line (`RustProviderBridge.logLine`), so the
/// file is kept private and bounded in one place; a line it could not write
/// goes to stderr.
func logHookDiagnostic(_ message: String) {
    guard let target = ProcessInfo.processInfo.environment["WEIR_HOOK_LOG"], !target.isEmpty else {
        return
    }
    guard target != "1", RustProviderBridge.logLine(message, to: target) else {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return
    }
}

func readBoundedStandardInput() throws -> Data {
    var input = Data()
    let limit = AgentIntegrationConfiguration.maximumHookInputBytes
    while input.count <= limit {
        let remaining = limit + 1 - input.count
        guard let chunk = try FileHandle.standardInput.read(
            upToCount: min(inputReadChunkBytes, remaining)
        ), !chunk.isEmpty else {
            return input
        }
        input.append(chunk)
    }
    throw AgentIntegrationError.invalidArguments("The provider approval request is too large.")
}

private struct HookInvocation: Encodable {
    let arguments: [String]
    let payload: String
}

/// Runs a lifecycle or worktree hook and exits the process with the
/// runtime's status. Only a successful worktree intercept exits non-zero;
/// every failure is logged by the runtime and exits zero so the agent is
/// never blocked by Weir.
func runLifecycleHook(provider: String, kind: RustProviderBridge.HookKind, arguments: [String] = []) -> Never {
    let input: Data
    do {
        if kind == .invocation {
            // Launch reports have no stdin; reading it would wait on the pane's terminal.
            let payload = arguments.first == "report" ? Data() : try readBoundedStandardInput()
            guard let text = String(data: payload, encoding: .utf8) else {
                throw AgentIntegrationError.invalidArguments("The hook payload is not UTF-8.")
            }
            input = try JSONEncoder().encode(HookInvocation(arguments: arguments, payload: text))
        } else {
            input = try readBoundedStandardInput()
        }
    } catch {
        logHookDiagnostic("Weir hook helper: \(error)")
        exit(0)
    }
    do {
        let outcome = try RustProviderBridge.runHook(
            provider: provider,
            kind: kind,
            payload: input,
            environment: ProcessInfo.processInfo.environment
        )
        if let message = outcome.message, outcome.exitCode != 0 {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
        if let stdout = outcome.stdout {
            FileHandle.standardOutput.write(Data(stdout.utf8))
        }
        if provider == "codex", kind == .lifecycle, outcome.outcome == .applied {
            CodexTurnFailureWatch.start(
                after: input,
                environment: ProcessInfo.processInfo.environment,
                helper: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            )
        }
        exit(outcome.exitCode)
    } catch {
        logHookDiagnostic("Weir hook helper: \(error)")
        exit(0)
    }
}

/// SIGTERM held back from the start of the process (`hold()`), so it can be read
/// instead of ending it. OpenCode's plugin sends one when the person answers at
/// OpenCode's own prompt, which stays up beside the card; no provider's hook is
/// waited on there, so the request has to be withdrawn, or the card would stay
/// until its timeout.
private struct PendingTermination {
    /// `sigset_t` is a bit mask on Darwin, and its macros are not imported.
    private static let mask = sigset_t(1) << sigset_t(SIGTERM - 1)

    static func hold() {
        var blocked = mask
        pthread_sigmask(SIG_BLOCK, &blocked, nil)
    }

    var isRequested: Bool {
        var pending = sigset_t()
        sigpending(&pending)
        return pending & Self.mask != 0
    }
}

func run(input: Data) throws -> Data? {
    guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "permission-request" else {
        throw AgentIntegrationError.invalidArguments(
            "Usage: AgentIntegrationHookHelper permission-request <provider>"
        )
    }
    let provider = CommandLine.arguments[2]
    let capabilities = RustProviderBridge.capabilities(provider: provider)
    let completion = capabilities.contains(ProviderCapabilityName.questionEndsWithTurn)
        ? AgentQuestionTurnCompletion(
            provider: provider, payload: input, environment: ProcessInfo.processInfo.environment
        )
        : nil
    let termination = capabilities.contains(ProviderCapabilityName.approvalWithdrawnBySignal)
        ? PendingTermination()
        : nil
    // Both are noticed between short waits for the decision.
    let isPolled = completion != nil || termination != nil
    guard let translated = try RustProviderBridge.approvalRequest(provider: provider, payload: input),
          let request = try JSONSerialization.jsonObject(with: translated) as? [String: Any],
          let toolName = request["tool_name"] as? String,
          let requestInput = request["input"],
          let timeoutMilliseconds = request["timeout_ms"] as? Int
    else {
        throw AgentIntegrationError.invalidArguments("The provider approval request is invalid.")
    }
    let client = try AgentIntegrationXPCClient(role: .requester)
    let bootstrap = try client.openSession()
    guard let runID = bootstrap.runID,
          try AgentIntegrationServiceArtifact.matchesBundle(
              bootstrap.serviceArtifact,
              containing: URL(fileURLWithPath: CommandLine.arguments[0])
          )
    else { throw AgentIntegrationError.invalidResponse }

    let hello = try AgentIntegrationApprovalWire.object(from: client.exchange(
        AgentIntegrationApprovalWire.hello(clientVersion: "weir-hook-helper-v1")
    ))
    let epoch = try AgentIntegrationApprovalWire.epoch(from: hello)
    let requestID = UUID()
    let submitted = try AgentIntegrationApprovalWire.object(from: client.exchange(
        AgentIntegrationApprovalWire.submit(
            epoch: epoch,
            submission: AgentIntegrationApprovalSubmission(
                runID: runID,
                requestID: requestID,
                provider: provider,
                sessionID: request["session_id"] as? String,
                operationID: completion?.operationID ?? request["operation_id"] as? String,
                toolName: toolName,
                summary: request["summary"] as? String,
                input: requestInput,
                questions: request["questions"],
                timeoutMilliseconds: timeoutMilliseconds,
                // The shim that started the agent minted it; the hook that
                // started us inherited it.
                agentRunID: ProcessInfo.processInfo.environment[HookHelperEnvironment.agentRunID].flatMap(UUID.init(uuidString:))
            )
        )
    ))
    guard submitted["type"] as? String == "approval.result" else {
        throw AgentIntegrationError.invalidResponse
    }
    // PermissionRequest has no tool_use_id, so identical inputs cannot
    // identify a completed question. Only this request's turn end may
    // release it without a controller decision.
    let waitDeadline = ProcessInfo.processInfo.systemUptime + Double(timeoutMilliseconds) / 1000
    var response: [String: Any]
    repeat {
        if completion?.hasCompleted() == true || termination?.isRequested == true {
            _ = try client.exchange(AgentIntegrationApprovalWire.cancel(
                epoch: epoch, runID: runID, requestID: requestID
            ))
            return nil
        }
        response = try AgentIntegrationApprovalWire.object(from: client.exchange(
            AgentIntegrationApprovalWire.wait(
                epoch: epoch, runID: runID, requestID: requestID,
                maximumWaitMilliseconds: isPolled ? 500 : timeoutMilliseconds
            ),
            timeoutSeconds: isPolled ? 5 : approvalWaitSeconds
        ))
        let state = (response["body"] as? [String: Any])?["state"] as? [String: Any]
        if state?["status"] as? String != "pending" {
            break
        }
    } while isPolled && ProcessInfo.processInfo.systemUptime < waitDeadline
    if completion?.hasCompleted() == true {
        return nil
    }
    guard response["type"] as? String == "approval.result",
          let body = response["body"] as? [String: Any],
          let state = body["state"] as? [String: Any],
          state["status"] as? String == "resolved",
          let result = state["result"] as? [String: Any],
          let decision = result["decision"] as? String
    else {
        return nil
    }
    let neutralDecision = AgentIntegrationApprovalWire.decisionBody(
        decision: decision,
        message: result["message"] as? String,
        answers: result["answers"] as? [String: String]
    )
    return try RustProviderBridge.approvalOutput(
        provider: provider,
        requestJSON: translated,
        decisionJSON: JSONSerialization.data(withJSONObject: neutralDecision)
    )
}

func publishLifecycleFallback(input: Data) {
    guard let provider = CommandLine.arguments.last,
          RustProviderBridge.capabilities(provider: provider)
          .contains(ProviderCapabilityName.approvalHookRecordsLifecycle)
    else { return }
    // Such a provider calls this helper instead of `weir-hook` for a
    // permission request, so the lifecycle record is written here, in-process.
    _ = try? RustProviderBridge.runHook(
        provider: provider,
        kind: .lifecycle,
        payload: input,
        environment: ProcessInfo.processInfo.environment
    )
}

// We stamp the invocation before the shim starts the agent. Unlike wall
// time, this clock keeps its order through clock adjustments and resolves
// launches within one second. A tmux endpoint cannot outlive this boot.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "launch-order" {
    FileHandle.standardOutput.write(Data("\(DispatchTime.now().uptimeNanoseconds)\n".utf8))
    exit(0)
}

if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == CodexTurnFailureWatch.subcommand {
    CodexTurnFailureWatch.run(arguments: CommandLine.arguments.dropFirst(2), environment: ProcessInfo.processInfo.environment)
    exit(0)
}

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == StatusLineRelay.subcommand {
    StatusLineRelay.run(provider: CommandLine.arguments[2], arguments: Array(CommandLine.arguments.dropFirst(3)))
}

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "hook" {
    let arguments = Array(CommandLine.arguments.dropFirst(3))
    let kind: RustProviderBridge.HookKind = switch arguments.first {
    case "worktree": .worktree
    case "event", "report": .invocation
    default: .lifecycle
    }
    runLifecycleHook(provider: CommandLine.arguments[2], kind: kind, arguments: arguments)
}

var input: Data?
do {
    let boundedInput = try readBoundedStandardInput()
    if (2...3).contains(CommandLine.arguments.count), CommandLine.arguments[1] == "question-turn-ended" {
        // Claude's settings name no provider; it was the only one when
        // they were written.
        let provider = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "claude"
        try AgentQuestionTurnCompletion.record(
            provider: provider, payload: boundedInput, environment: ProcessInfo.processInfo.environment
        )
        exit(0)
    }
    input = boundedInput
    if let output = try run(input: boundedInput) {
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        publishLifecycleFallback(input: boundedInput)
    }
} catch {
    // No output delegates to the provider's native permission flow. Never
    // convert an integration or decoding failure into an approval decision.
    logHookDiagnostic("Weir approval helper: \(error)")
    if let input {
        publishLifecycleFallback(input: input)
    }
}
