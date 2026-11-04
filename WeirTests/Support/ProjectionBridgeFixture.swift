// ProjectionBridgeFixture.swift
// Weir — builds the input, records, and clocks one projection pass is given, and runs the pass.
//
// Suites that drive the rules through the bridge itself, rather than through
// an adapter (`ProjectionFixture`), share these. A pass is never committed
// here: a suite that needs what a pass proposed kept commits it itself.

import Foundation
@testable import Weir

enum ProjectionBridgeFixture {
    /// An empty input with every provider this build has, as the registry
    /// reports them.
    static func input() throws -> AgentProjectionInput {
        var input = AgentProjectionInput()
        input.providers = try AgentProviderDescriptor.registry(from: WeirProjectionBridge.providers())
        return input
    }

    /// A record file whose content is `record` as JSON.
    static func file(provider: String, name: String, record: [String: Any]) throws -> AgentProjectionFile {
        try AgentProjectionFile(
            provider: provider,
            name: name,
            content: String(data: JSONSerialization.data(withJSONObject: record), encoding: .utf8)
        )
    }

    /// Both clocks at `wall` and `monotonicMs`.
    static func now(_ wall: String, monotonicMs: UInt64) throws -> Data {
        try JSONEncoder().encode(AgentProjectionInstant(wall: wall, monotonicMs: monotonicMs))
    }

    /// One pass over `input` at `now`, with what it proposed to remember.
    static func pass(
        _ input: AgentProjectionInput,
        now: Data,
        engine: WeirProjectionBridge.Engine = WeirProjectionBridge.Engine()
    ) throws -> (response: AgentProjectionResponse, proposal: UInt64) {
        let pass = try engine.pass(input: JSONEncoder().encode(input), now: now)
        return try (JSONDecoder().decode(AgentProjectionResponse.self, from: pass.body), pass.proposal)
    }
}
