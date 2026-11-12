// HookHelperFixture.swift
// Weir — locates the bundled Hook Helper beside the test host.

import Foundation
import Testing

enum HookHelperFixture {
    /// The `AgentIntegrationHookHelper` embedded beside the test host's
    /// executable; `nil` when the test bundle runs without its app host, which
    /// is a missing precondition rather than a failure.
    static let helperURL: URL? = {
        guard let executable = Bundle.main.executableURL else { return nil }
        let helper = executable.deletingLastPathComponent().appendingPathComponent("AgentIntegrationHookHelper")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }()
}

/// Decodes a recording stub's NUL-separated report arguments for shim assertions.
enum HookReportFixture {
    static func object(_ data: Data) throws -> [String: Any] {
        let text = try #require(String(data: data, encoding: .utf8))
        var arguments = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        #expect(arguments.popLast() == "")
        try #require(arguments.count >= 4)
        #expect(arguments[0] == "hook")
        #expect(arguments[2] == "report")
        var object: [String: Any] = ["hook_event_name": arguments[3]]
        var index = 4
        while index < arguments.count {
            let kind = arguments[index]
            try #require(index + 1 < arguments.count)
            let name = arguments[index + 1]
            if kind == "--empty-object" {
                object[name] = [String: String]()
                index += 2
                continue
            }
            try #require(index + 2 < arguments.count)
            let value = arguments[index + 2]
            switch kind {
            case "--string": object[name] = value
            case "--string-array": object[name] = [value]
            case "--boolean": object[name] = try #require(Bool(value))
            default: Issue.record("Unexpected report field type: \(kind)")
            }
            index += 3
        }
        return object
    }
}
