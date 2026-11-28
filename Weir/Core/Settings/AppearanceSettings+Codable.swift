// AppearanceSettings+Codable.swift
// Weir — how `AppearanceSettings` reads and writes its section of `settings.json`.

import Foundation

extension AppearanceSettings {
    /// We ship a defensive `init(from:)`, as the other sections do, so
    /// older `settings.json` files decode cleanly when a new field is added
    /// or an old one renamed, instead of throwing and falling back to a
    /// fresh defaults document that would also wipe the user's
    /// `accentColor`, `backgroundOpacity`, and `transparency`. Every field here is a
    /// visible Settings choice — losing them mid-upgrade is the kind
    /// of regression a user notices immediately. It lives in an extension
    /// so the struct keeps its synthesized `init()`.
    init(from decoder: any Decoder) throws {
        // Every field defaults if absent, so a file from an older build
        // decodes (`docs/data-migration.md`).
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.accentColor = try c.decodeIfPresent(AccentColor.self, forKey: .accentColor) ?? .default
        self.backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.92
        self.transparency = try c.decodeIfPresent(TransparencyMode.self, forKey: .transparency) ?? .on
        self.colorScheme = try c.decodeIfPresent(ColorSchemePreference.self, forKey: .colorScheme) ?? .system
        let rawUnfocused = try c.decodeIfPresent(Double.self, forKey: .unfocusedPaneOpacity) ?? 0.7
        self.unfocusedPaneOpacity = min(1.0, max(0.15, rawUnfocused))
        // `try?`: a `terminalTheme` that is not an object at all falls back
        // to the bundled pair rather than failing the whole section.
        self.terminalTheme = (try? c.decodeIfPresent(TerminalThemeSelection.self, forKey: .terminalTheme))
            ?? TerminalThemeSelection()
        self.unknownFields = try CodableSidecar.decodeUnknownFields(
            from: decoder,
            knownKeys: Self.knownKeyStrings
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accentColor, forKey: .accentColor)
        try c.encode(backgroundOpacity, forKey: .backgroundOpacity)
        try c.encode(transparency, forKey: .transparency)
        try c.encode(colorScheme, forKey: .colorScheme)
        try c.encode(unfocusedPaneOpacity, forKey: .unfocusedPaneOpacity)
        // Written even when it is the default, `{}`, as the other fields
        // are: the verification channel finds a setting by its key in the
        // encoded file (`AutomationSettings`).
        try c.encode(terminalTheme, forKey: .terminalTheme)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case accentColor
        case backgroundOpacity
        case transparency
        case colorScheme
        case unfocusedPaneOpacity
        case terminalTheme
    }

    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))
}
