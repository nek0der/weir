// AgentProviderDescriptor.swift
// Weir — what a provider declares about itself, and how its registry is decoded.
//
// Lives in `ProviderBridge/` so the app and the Hook Helper decode the
// registry `weir_projection_providers_v1` reports with the same type.

import Foundation

/// What a provider declares about itself, as the Rust registry reports it.
/// The host reads only some of it, but every field is named here: the
/// descriptors go back to the rules in each pass's input, and a field left
/// out would reach them as its default (`WeirProjectionBridgeTests` holds
/// the round trip to the registry's own JSON).
struct AgentProviderDescriptor: Codable, Sendable {
    var id: String
    var displayName: String
    var capabilities: [String]
    var pidSweepIntervalMs: Int
    var stateDirectory: String
    var sessionDirectory: String
    var cwdEventsDirectory: String?
    var processNames: [String]
    var sessionEndDropReasons: [String]
    var internalAgentDirectories: [String]
    /// The `app` name the provider's agent gives itself in OSC 7501, when it
    /// reports its status.
    var programStatusApp: String?
}

extension AgentProviderDescriptor {
    /// Every descriptor in `registry`, by provider id. Throws when any one
    /// does not decode: the app sends them all back to the rules.
    static func registry(from registry: Data) throws -> [String: AgentProviderDescriptor] {
        try JSONDecoder().decode([String: AgentProviderDescriptor].self, from: registry)
    }

    /// `provider`'s descriptor in `registry`, or `nil` when the registry has
    /// no such provider. Only this provider's descriptor has to decode, so
    /// one provider's malformed descriptor does not take every other
    /// provider's hooks down.
    static func descriptor(_ provider: String, in registry: Data) throws -> AgentProviderDescriptor? {
        let entries = try JSONDecoder().decode([String: Entry].self, from: registry)
        return try entries[provider]?.descriptor.get()
    }

    /// One provider's descriptor, decoded on its own so a failure stays with it.
    private struct Entry: Decodable {
        let descriptor: Result<AgentProviderDescriptor, any Error>

        init(from decoder: any Decoder) throws {
            descriptor = Result { try AgentProviderDescriptor(from: decoder) }
        }
    }
}
