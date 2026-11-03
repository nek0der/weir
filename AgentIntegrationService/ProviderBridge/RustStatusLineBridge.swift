// RustStatusLineBridge.swift
// Weir — Swift wrapper around the status line relay's C ABI, for the Hook Helper.

import Foundation
import WeirRustBridge

/// The status line calls of the Rust bridge: the relay itself and the setting
/// the shim launches the provider with. Only the Hook Helper makes them; the
/// app reads the record the relay writes.
enum RustStatusLineBridge {
    /// Runs the status line relay on one input: keeps its usage, and returns
    /// the person's own status line command, or `nil` when they have none.
    /// Keeping the usage never fails the call; finding their command does
    /// not depend on it.
    static func command(provider: String, input: Data, environment: [String: String]) throws -> String? {
        // The provider writes JSON, which is UTF-8. Input that is not still
        // has a status line to run: it is looked up as for a session with no
        // project (an empty document), and only the usage goes unread.
        let text = String(bytes: input, encoding: .utf8) ?? "{}"
        let request = CommandRequest(provider: provider, input: text, environment: environment)
        return try command(fromAnswer: call(JSONEncoder().encode(request), weir_status_line_run_v1))
    }

    /// The person's command in the relay's answer. A `command` that is not a
    /// string reads as none, as it did when the answer was read as a
    /// dictionary; an answer that is not an object is no answer.
    static func command(fromAnswer answer: Data) throws -> String? {
        do {
            return try JSONDecoder().decode(StatusLineCommandAnswer.self, from: answer).command
        } catch {
            throw AgentIntegrationError.invalidResponse
        }
    }

    /// The status line setting the provider is launched with: the person's
    /// own as it stands for `workingDirectory`, with `relayCommand` in its
    /// place. `nil` when they have none, and the slot stays empty.
    static func setting(
        provider: String,
        environment: [String: String],
        workingDirectory: String,
        relayCommand: String
    ) throws -> [String: Any]? {
        let request = SettingRequest(
            provider: provider,
            environment: environment,
            workingDirectory: workingDirectory,
            relayCommand: relayCommand
        )
        let answer = try call(JSONEncoder().encode(request), weir_status_line_setting_v1)
        // Read untyped: the setting is the person's own object, which goes
        // back into their settings document as it came.
        guard let object = try JSONSerialization.jsonObject(with: answer) as? [String: Any] else {
            throw AgentIntegrationError.invalidResponse
        }
        switch object["statusLine"] {
        case let setting as [String: Any]: return setting
        case is NSNull: return nil
        default: throw AgentIntegrationError.invalidResponse
        }
    }

    private struct CommandRequest: Encodable {
        let provider: String
        let input: String
        let environment: [String: String]
    }

    private struct SettingRequest: Encodable {
        let provider: String
        let environment: [String: String]
        let workingDirectory: String
        let relayCommand: String
    }

    private typealias Function = (
        UnsafePointer<UInt8>?, Int,
        UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int>?
    ) -> Int32

    private static func call(_ request: Data, _ function: Function) throws -> Data {
        let output = RustBytes.call { out, outCount in
            RustBytes.withBytes(request) { pointer, count in
                function(pointer, count, out, outCount)
            }
        }
        guard output.status == Int32(WEIR_USAGE_OK.rawValue), let body = output.body else {
            throw AgentIntegrationError.rustFailure(output.status)
        }
        return body
    }
}

/// The relay's answer (`RustStatusLineBridge.command(fromAnswer:)`).
private struct StatusLineCommandAnswer: Decodable {
    let command: String?

    private enum CodingKeys: String, CodingKey {
        case command
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try? container.decodeIfPresent(String.self, forKey: .command)
    }
}
