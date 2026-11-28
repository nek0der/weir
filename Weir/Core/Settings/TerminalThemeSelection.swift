// TerminalThemeSelection.swift
// Weir — the terminal themes the person chose for light and dark appearance, as `settings.json` holds them.

import Foundation
import WeirDomain

/// Where a terminal theme file comes from. Stored as its raw string.
enum TerminalThemeOrigin: String, Codable, CaseIterable, Sendable {
    /// Weir's own bundle (`<resources>/themes`).
    case bundled
    /// The person's Ghostty themes folder (`$XDG_CONFIG_HOME/ghostty/themes`).
    case user
    /// An installed Ghostty app's themes.
    case ghostty
}

/// One theme the person chose: a file name and the folder it is found in.
///
/// The name is a file name, not a path, so a moved home folder or an app
/// bundle update still finds it. `TerminalThemeCatalog.resolve(_:)` turns it
/// into a path and rejects a name that could leave its folder.
struct TerminalThemeRef: Codable, Equatable, Hashable, Sendable {
    var name: String
    var origin: TerminalThemeOrigin

    /// See `WeirSettings.unknownFields`. Left out of the hash, which equal
    /// values still share because equality compares it too.
    var unknownFields: [String: WeirJSONValue] = [:]

    init(name: String, origin: TerminalThemeOrigin) {
        self.name = name
        self.origin = origin
    }

    /// Throws when `name` is missing or `origin` is not one this build knows.
    /// `TerminalThemeSelection` catches that and keeps the raw value, so a
    /// newer build's origin survives a rollback instead of being guessed.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        let rawOrigin = try c.decode(String.self, forKey: .origin)
        guard let origin = TerminalThemeOrigin(rawValue: rawOrigin) else {
            throw DecodingError.dataCorruptedError(
                forKey: .origin,
                in: c,
                debugDescription: "unknown terminal theme origin"
            )
        }
        self.origin = origin
        self.unknownFields = try CodableSidecar.decodeUnknownFields(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(origin, forKey: .origin)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(origin)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, origin
    }
}

/// How far a terminal theme colors the window.
enum TerminalThemeScope: String, Sendable {
    /// The terminal's colors and ground, and the review's syntax colors.
    case terminal
    /// The window's neutral colors as well (`WindowColorResolver`).
    case window
}

/// The terminal theme for each appearance. A `nil` side uses the bundled
/// default for that side (`Apple System Colors Light` / `Apple System Colors`).
struct TerminalThemeSelection: Codable, Equatable, Sendable {
    var light: TerminalThemeRef?
    var dark: TerminalThemeRef?

    /// How far the theme colors the window, as stored: `nil` until the
    /// person sets it, which reads as `.terminal`. Kept as the raw string,
    /// so a value a newer build wrote survives this one unchanged.
    var scopeValue: String?

    /// How far the theme colors the window. An unset or unknown value is
    /// `.terminal`, the look the window had before the setting existed.
    var scope: TerminalThemeScope {
        get { scopeValue.flatMap(TerminalThemeScope.init(rawValue:)) ?? .terminal }
        set { scopeValue = newValue == .terminal ? nil : newValue.rawValue }
    }

    /// See `WeirSettings.unknownFields`.
    var unknownFields: [String: WeirJSONValue] = [:]

    /// A side this build could not read (an unknown `origin`, say), as raw
    /// JSON under the side's key, so it is written back unchanged until the
    /// person picks a theme for that side. Kept apart from `unknownFields`
    /// because the key is one this build knows: only its value is not.
    var unreadableSides: [String: WeirJSONValue] = [:]

    init(light: TerminalThemeRef? = nil, dark: TerminalThemeRef? = nil) {
        self.light = light
        self.dark = dark
    }

    /// Whether this is the selection a fresh settings file has, written as
    /// `{}`.
    var isDefault: Bool {
        light == nil && dark == nil && scopeValue == nil && unknownFields.isEmpty && unreadableSides.isEmpty
    }

    /// The choice for `side`; `nil` is the bundled default.
    func ref(for side: TerminalThemeBrightness) -> TerminalThemeRef? {
        switch side {
        case .light: light
        case .dark: dark
        }
    }

    /// Chooses `ref` for `side`, `nil` for the bundled default, and drops
    /// the raw value a newer build stored for that side and this one could
    /// not read. Whatever the person picks replaces that value, the default
    /// included, so a theme they moved away from is not written back.
    mutating func choose(_ ref: TerminalThemeRef?, for side: TerminalThemeBrightness) {
        switch side {
        case .light: light = ref
        case .dark: dark = ref
        }
        unreadableSides.removeValue(forKey: side.rawValue)
    }

    /// Never throws for a malformed side: that side reads as `nil` and its
    /// raw JSON stays in `unreadableSides`. Only a value that is not a JSON
    /// object at all throws, and `AppearanceSettings` catches that.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var unreadable: [String: WeirJSONValue] = [:]
        func side(_ key: CodingKeys) -> TerminalThemeRef? {
            guard c.contains(key) else { return nil }
            if let ref = try? c.decode(TerminalThemeRef.self, forKey: key) {
                return ref
            }
            // `try?`: any JSON value decodes as `WeirJSONValue`; an explicit
            // `null` means no choice and is not worth keeping.
            if let raw = try? c.decode(WeirJSONValue.self, forKey: key), raw != .null {
                unreadable[key.stringValue] = raw
            }
            return nil
        }
        self.light = side(.light)
        self.dark = side(.dark)
        // `try?`: a scope that is not a string is no choice, and dropped.
        self.scopeValue = try? c.decodeIfPresent(String.self, forKey: .scope)
        self.unknownFields = try CodableSidecar.decodeUnknownFields(from: decoder, knownKeys: CodingKeys.self)
        self.unreadableSides = unreadable
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // A side the person has chosen replaces whatever raw value this
        // build could not read, so the key is never written twice.
        for (key, ref) in [(CodingKeys.light, light), (.dark, dark)] {
            if let ref {
                try c.encode(ref, forKey: key)
            } else if let raw = unreadableSides[key.stringValue] {
                try c.encode(raw, forKey: key)
            }
        }
        try c.encodeIfPresent(scopeValue, forKey: .scope)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case light, dark, scope
    }
}
