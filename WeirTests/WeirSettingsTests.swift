// WeirSettingsTests.swift
// Weir — settings defaults, the persisted JSON shape, and compatibility across versions.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("WeirSettings")
struct WeirSettingsTests {

    // MARK: - Defaults

    private static let legacy = Data(#"""
    {
      "schemaVersion": 1,
      "appearance": {"accentColor": "blue", "backgroundOpacity": 0.65, "transparency": "off"},
      "font": {"size": 17, "ligatures": true, "lineHeight": 2},
      "terminal": {"scrollbackLines": 27000, "bellAction": "audio", "cursorStyle": "bar", "cursorBlink": "off"},
      "advanced": {"hostsAgentsInTmux": true, "reviewInstructions": "Keep this note."}
    }
    """#.utf8)

    @Test("appearance defaults: transparency enabled, default accent, near-opaque pane background")
    func default_appearanceDefaults() {
        let s = WeirSettings.default.appearance
        #expect(s.transparency == .on)
        #expect(s.accentColor == .default)
        #expect(s.backgroundOpacity == 0.92)
        #expect(s.unfocusedPaneOpacity == 0.7)
    }

    @Test("font defaults: nil family lets libghostty pick the system mono")
    func default_fontDefaults() {
        let s = WeirSettings.default.font
        #expect(s.family == nil)
        #expect(s.size == 13)
        #expect(s.ligatures == false)
        #expect(s.lineHeight == 0)
    }

    // MARK: - Codable round-trip

    @Test func theDefaultFile_writesItsCurrentVersionAndSections() throws {
        let original = WeirSettings.default
        let data = try WeirSettings.makeFileEncoder().encode(original)
        let object = try JSONObjectFixture.object(data)
        let sections = [
            "appearance", "font", "terminal", "keyboard", "confirmations", "advanced", "quickTerminal", "review", "general", "newSession"
        ]

        #expect(original.schemaVersion == WeirSettings.currentSchemaVersion)
        #expect(object["schemaVersion"] as? Int == WeirSettings.currentSchemaVersion)
        #expect(object["jumpOpensTurnReview"] as? Bool == true)
        for section in sections {
            #expect(object[section] is [String: Any], "expected the \(section) section")
        }
        #expect(try JSONDecoder().decode(WeirSettings.self, from: data) == original)
    }

    /// Every field touched here is moved *off* its default, so a
    /// dropped `CodingKey` shows up as a mismatch. A field assigned its
    /// own default would round-trip either way and pin nothing.
    @Test("encode → decode yields an equivalent value")
    func codable_customized_roundTrip() throws {
        var settings = WeirSettings.default
        settings.appearance.transparency = .off
        settings.appearance.accentColor = .blue
        settings.appearance.backgroundOpacity = 0.5
        settings.appearance.unfocusedPaneOpacity = 0.45
        settings.font.family = "Fira Code"
        settings.font.size = 15
        settings.font.ligatures = true
        settings.font.lineHeight = 2
        settings.terminal.scrollbackLines = 25000
        settings.terminal.quickTabCwdMode = .fixed
        settings.terminal.quickTabCwdPath = URL(fileURLWithPath: "/tmp/weir-quicktab")
        settings.advanced.hostsAgentsInTmux = true
        settings.advanced.holdsApprovals = false
        settings.advanced.reviewInstructions = "Fix these."
        settings.advanced.fileApplication = FileApplication(
            bundleIdentifier: "com.example.Editor",
            lastKnownDisplayName: "Example Editor"
        )
        settings.jumpOpensTurnReview = false
        settings.general.showMenuBarExtra = false
        settings.general.notifyOnUsageLimitReset = true
        settings.advanced.turnRetention = TurnRetentionSettings(days: 30, turns: 120)

        let data = try WeirSettings.makeFileEncoder().encode(settings)
        let restored = try JSONDecoder().decode(WeirSettings.self, from: data)
        #expect(restored == settings)
    }

    @Test func jumpReview_defaultsOnForNewAndOlderSettings() throws {
        #expect(WeirSettings.default.jumpOpensTurnReview)

        let decoded = try JSONDecoder().decode(WeirSettings.self, from: Self.legacy)

        #expect(decoded.jumpOpensTurnReview)
        #expect(decoded.font.size == 17)
    }

    @Test func existingAdvancedSettingsDefaultReviewFields() throws {
        let data = Data(#"{"hostsAgentsInTmux":true}"#.utf8)
        let restored = try JSONDecoder().decode(AdvancedSettings.self, from: data)
        #expect(restored.hostsAgentsInTmux)
        #expect(restored.reviewInstructions.isEmpty)
        #expect(restored.fileApplication == nil)
    }

    /// The preference predates its use outside Review; a settings file that
    /// already chose an app must keep it.
    @Test func fileApplication_keepsItsStoredKey() throws {
        let data = Data(#"{"reviewFileApplication":{"bundleIdentifier":"com.example.Editor","lastKnownDisplayName":"Example Editor"}}"#
            .utf8)
        let restored = try JSONDecoder().decode(AdvancedSettings.self, from: data)
        #expect(restored.fileApplication == FileApplication(
            bundleIdentifier: "com.example.Editor", lastKnownDisplayName: "Example Editor"
        ))

        let object = try JSONObjectFixture.object(encoding: restored)
        #expect(object["reviewFileApplication"] as? [String: String] == [
            "bundleIdentifier": "com.example.Editor", "lastKnownDisplayName": "Example Editor"
        ])
        #expect(object["fileApplication"] == nil)
    }

    // MARK: - Compatibility with earlier settings files

    @Test(arguments: ["appearance", "font", "terminal", "advanced"])
    func aMissingRequiredSection_isReportedByKey(_ section: String) throws {
        var object = try JSONObjectFixture.object(Self.legacy)
        try #require(object.removeValue(forKey: section) != nil)

        do {
            _ = try WeirSettingsJSON.decode(object)
            Issue.record("expected the missing \(section) section to fail decoding")
        } catch let DecodingError.keyNotFound(key, context) {
            #expect(key.stringValue == section)
            #expect(context.codingPath.isEmpty)
        }
    }

    @Test("unknown `accentColor` raw value falls back to `.default`")
    func decode_unknownAccentRaw_fallsBackToDefault() throws {
        // `AccentColor` ships its own `init(from:)` that maps any
        // unknown rawValue (e.g. `graphite` written by a pre-release
        // build, or a future case rolled back) to `.default` instead
        // of throwing a `DecodingError` that would poison the whole
        // `AppearanceSettings` decode.
        let data = Data(#"""
        {"schemaVersion":1,
         "appearance":{"accentColor":"graphite","backgroundOpacity":0.65,"transparency":"off","colorScheme":"dark"},
         "font":{"size":13,"ligatures":false,"lineHeight":0},
         "terminal":{},
         "advanced":{"ghosttyConfig":"off"}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(WeirSettings.self, from: data)
        #expect(decoded.appearance.accentColor == .default)
        #expect(decoded.appearance.backgroundOpacity == 0.65)
        #expect(decoded.appearance.transparency == .off)
        #expect(decoded.appearance.colorScheme == .dark)
    }

    @Test("terminal section without quickTab keys decodes with cwd defaults")
    func decode_terminalMissingQuickTabKeys_defaults() throws {
        let terminal = try JSONDecoder().decode(WeirSettings.self, from: Self.legacy).terminal

        #expect(terminal.quickTabCwdMode == .inheritPrevious)
        #expect(terminal.quickTabCwdPath == nil)
        #expect(terminal.scrollbackLines == 27000)
        #expect(terminal.bellAction == .audio)
        #expect(terminal.cursorStyle == .bar)
        #expect(terminal.cursorBlink == .off)
    }

    /// The pane header setting is gone: panes show their header by the
    /// rule alone. A file an earlier build wrote still decodes, and its
    /// value is kept as written for that build to read again.
    @Test func retiredPaneHeaderSetting_decodesAndIsKeptForEarlierBuilds() throws {
        let decoded = try JSONDecoder().decode(
            TerminalSettings.self,
            from: Data(#"{"showsSplitPaneHeaders":false}"#.utf8)
        )
        #expect(decoded.unknownFields["showsSplitPaneHeaders"] == .bool(false))
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        #expect(written?["showsSplitPaneHeaders"] as? Bool == false)
    }

    /// A pane minimum saved under the old 40pt floor is raised to 60, the
    /// range's lower bound.
    @Test(
        "terminal pane minimum is clamped to the supported settings range",
        arguments: [(1, 60), (40, 60), (1000, 300)] as [(Int, Double)]
    )
    func decode_terminalPaneMinimum_clampsToSupportedRange(written: Int, read: Double) throws {
        let decoded = try JSONDecoder().decode(
            TerminalSettings.self,
            from: Data(#"{"minPaneSize":\#(written)}"#.utf8)
        )
        #expect(decoded.minPaneSize == read)
    }

    @Test("unfocused pane opacity is clamped to its supported range")
    func decode_unfocusedPaneOpacity_clampsToSupportedRange() throws {
        let belowRange = try JSONDecoder().decode(
            AppearanceSettings.self,
            from: Data(#"{"unfocusedPaneOpacity":0}"#.utf8)
        )
        let aboveRange = try JSONDecoder().decode(
            AppearanceSettings.self,
            from: Data(#"{"unfocusedPaneOpacity":2}"#.utf8)
        )

        #expect(belowRange.unfocusedPaneOpacity == 0.15)
        #expect(aboveRange.unfocusedPaneOpacity == 1.0)
    }

    /// A file that never stored the hold setting keeps holding. Turning it
    /// off writes the legacy key beside any keys from a newer build.
    @Test func approvalHold_writesOnlyOptOut_andKeepsUnknownKeys() throws {
        let untouched = try JSONObjectFixture.object(encoding: AdvancedSettings())
        #expect(untouched["approvalHoldWhileHidden"] == nil)

        let legacy = try JSONDecoder().decode(AdvancedSettings.self, from: Data("{}".utf8))
        #expect(legacy.holdsApprovals)

        let data = Data(#"{"approvalHoldWhileHidden":false,"futureKey":1}"#.utf8)
        let decoded = try JSONDecoder().decode(AdvancedSettings.self, from: data)
        let written = try JSONObjectFixture.object(encoding: decoded)

        #expect(!decoded.holdsApprovals)
        #expect(decoded.unknownFields["futureKey"] == .int(1))
        #expect(written["approvalHoldWhileHidden"] as? Bool == false)
        #expect(written["futureKey"] as? Int == 1)
    }

    /// Earlier builds wrote both pull-request switches into every
    /// settings file. This build reads neither (pull requests show
    /// wherever `gh` or `glab` can read them), and writes both back as
    /// they were, so a build that still reads them finds the person's
    /// value after a rollback.
    @Test func removedPRToggles_areKeptInUnknownFieldsAndIgnored() throws {
        func file(schemaVersion: Int) -> Data {
            Data("""
            {"schemaVersion":\(schemaVersion),
             "appearance":{"accentColor":"default","backgroundOpacity":0.92,"transparency":"on"},
             "font":{"size":13,"ligatures":false,"lineHeight":0},
             "terminal":{},
             "advanced":{"ghosttyConfig":"off",
                         "showPRStatusInSidebar":true,
                         "showPRStatusOnlyWhenAttention":false}}
            """.utf8)
        }
        let data = file(schemaVersion: 2)
        let decoded = try JSONDecoder().decode(WeirSettings.self, from: data)

        // Ignored: they are only carried, and every setting the type reads
        // is its default.
        #expect(decoded.advanced.unknownFields == [
            "showPRStatusInSidebar": .bool(true),
            "showPRStatusOnlyWhenAttention": .bool(false)
        ])
        var typed = decoded.advanced
        typed.unknownFields = [:]
        #expect(typed == AdvancedSettings())

        // Written back unchanged.
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        let advanced = try #require(written?["advanced"] as? [String: Any])
        #expect(advanced["showPRStatusInSidebar"] as? Bool == true)
        #expect(advanced["showPRStatusOnlyWhenAttention"] as? Bool == false)

        // An existing person's file is schema 1, which reaches this build
        // through the migration; the keys come out of it as they went in.
        guard case let .migrated(from, migrated) = try VersionedDocumentMigrator.settings.migrate(file(schemaVersion: 1)) else {
            Issue.record("a schema 1 file is migrated")
            return
        }
        #expect(from == 1)
        let migratedFile = try JSONSerialization.jsonObject(with: migrated) as? [String: Any]
        #expect(migratedFile?["schemaVersion"] as? Int == WeirSettings.currentSchemaVersion)
        let migratedAdvanced = try #require(migratedFile?["advanced"] as? [String: Any])
        #expect(migratedAdvanced["showPRStatusInSidebar"] as? Bool == true)
        #expect(migratedAdvanced["showPRStatusOnlyWhenAttention"] as? Bool == false)

        // A file that never had them does not grow them.
        let fresh = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WeirSettings.default)) as? [String: Any]
        let freshAdvanced = try #require(fresh?["advanced"] as? [String: Any])
        #expect(freshAdvanced["showPRStatusInSidebar"] == nil)
        #expect(freshAdvanced["showPRStatusOnlyWhenAttention"] == nil)
    }

    // MARK: - Forward-compat decoders

    @Test("ConfirmPolicy with an unknown raw value falls back to .onlyWhenAgent")
    func confirmPolicy_unknownRaw_fallsBackToOnlyWhenAgent() throws {
        // Synthesised `String` decoding would throw on this raw value;
        // the custom `init(from:)` we ship instead routes it to the
        // configured fallback so a newer build's added case can't
        // brick the older build's settings.json read.
        let json = Data("\"future-case-not-yet-added\"".utf8)
        let decoded = try JSONDecoder().decode(ConfirmPolicy.self, from: json)
        #expect(decoded == .onlyWhenAgent)
    }

    // MARK: - Sidecar forward-compat round-trip

    @Test func unknownRootAndAppearanceFields_surviveFileEncoding() throws {
        var object = try JSONObjectFixture.object(Self.legacy)
        var appearance = try #require(object["appearance"] as? [String: Any])
        appearance["futureDarkModeAccent"] = "#ff00aa"
        object["appearance"] = appearance
        object["futurePluginSection"] = ["enabled": true, "label": "plug-A"]

        let decoded = try WeirSettingsJSON.decode(object)
        #expect(decoded.unknownFields["futurePluginSection"] == .object(["enabled": .bool(true), "label": .string("plug-A")]))
        #expect(decoded.appearance.unknownFields["futureDarkModeAccent"] == .string("#ff00aa"))
        #expect(decoded.appearance.accentColor == .blue)

        let written = try JSONObjectFixture.object(encoding: decoded, with: WeirSettings.makeFileEncoder())
        let plugin = try #require(written["futurePluginSection"] as? [String: Any])
        let savedAppearance = try #require(written["appearance"] as? [String: Any])
        #expect(plugin["enabled"] as? Bool == true)
        #expect(plugin["label"] as? String == "plug-A")
        #expect(savedAppearance["futureDarkModeAccent"] as? String == "#ff00aa")
        #expect(savedAppearance["accentColor"] as? String == "blue")
        #expect(written["futureDarkModeAccent"] == nil)
    }

    // MARK: - Review

    @Test func theReviewSection_isOptional_andRoundTrips_keepingWhatANewerBuildWrote() throws {
        #expect(WeirSettings().review.externalDiffCommand.isEmpty)
        let older = try JSONDecoder().decode(WeirSettings.self, from: Self.legacy)
        #expect(older.review == ReviewSettings())
        #expect(older.font.size == 17)

        var object = try JSONObjectFixture.object(Self.legacy)
        object["review"] = ["externalDiffCommand": "tig --all", "fromLater": 7]
        let decoded = try WeirSettingsJSON.decode(object)
        #expect(decoded.review.externalDiffCommand == "tig --all")
        #expect(decoded.review.unknownFields == ["fromLater": .int(7)])

        let written = try JSONObjectFixture.object(encoding: decoded, with: WeirSettings.makeFileEncoder())
        let review = try #require(written["review"] as? [String: Any])
        #expect(review["externalDiffCommand"] as? String == "tig --all")
        #expect(review["fromLater"] as? Int == 7)
    }

    // MARK: - General, new session, and retention sections

    @Test func theNewSettings_startAtTheirDefaults() {
        let settings = WeirSettings.default

        #expect(settings.general.showMenuBarExtra)
        #expect(!settings.general.notifyOnUsageLimitReset)
        #expect(settings.newSession.lastAgent == nil)
        #expect(settings.advanced.turnRetention.days == 14)
        #expect(settings.advanced.turnRetention.turns == 200)
        #expect(settings.advanced.turnRetention.limits == TurnRetentionLimits.standard)
    }

    @Test func aFileWrittenBeforeThem_readsTheDefaults() throws {
        let settings = try JSONDecoder().decode(WeirSettings.self, from: Self.legacy)

        #expect(settings.general == GeneralSettings())
        #expect(settings.newSession == NewSessionSettings())
        #expect(settings.advanced.turnRetention == TurnRetentionSettings())
        #expect(settings.appearance.accentColor == .blue)
        #expect(settings.font.size == 17)
        #expect(settings.advanced.hostsAgentsInTmux)
        #expect(settings.advanced.reviewInstructions == "Keep this note.")
    }

    @Test func keysALaterBuildAdded_toTheNewSections_areWrittenBack() throws {
        var object = try JSONObjectFixture.object(encoding: WeirSettings.default)
        object["general"] = ["showMenuBarExtra": false, "laterKey": 1]
        object["newSession"] = ["laterKey": "x"]
        var advanced = try #require(object["advanced"] as? [String: Any])
        advanced["turnRetention"] = ["days": 20, "turns": 100, "laterKey": true]
        object["advanced"] = advanced

        let written = try JSONObjectFixture.object(encoding: WeirSettingsJSON.decode(object))

        let general = try #require(written["general"] as? [String: Any])
        #expect(general["laterKey"] as? Int == 1)
        #expect(general["showMenuBarExtra"] as? Bool == false)
        #expect((written["newSession"] as? [String: Any])?["laterKey"] as? String == "x")
        let retention = try #require((written["advanced"] as? [String: Any])?["turnRetention"] as? [String: Any])
        #expect(retention["laterKey"] as? Bool == true)
        #expect(retention["days"] as? Int == 20)
        #expect(retention["turns"] as? Int == 100)
    }

    @Test func generalSettings_dropTheMovedGroupCounts_andCarryTheGuideDismissal() throws {
        let written = Data(#"""
        {"showMenuBarExtra":false,"movedGroups":{"groups":2,"tabs":4},"isFirstRunGuideDismissed":true,"later":1}
        """#.utf8)
        let general = try JSONDecoder().decode(GeneralSettings.self, from: written)
        #expect(!general.showMenuBarExtra)
        #expect(general.unknownFields == ["isFirstRunGuideDismissed": .bool(true), "later": .int(1)])

        let saved = try JSONObjectFixture.object(encoding: general)
        #expect(saved["movedGroups"] == nil)
        #expect(saved["showMenuBarExtra"] as? Bool == false)
        #expect(saved["isFirstRunGuideDismissed"] as? Bool == true)
        #expect(saved["later"] as? Int == 1)

        let fresh = try JSONObjectFixture.object(encoding: GeneralSettings())
        #expect(fresh["movedGroups"] == nil)
        #expect(fresh["isFirstRunGuideDismissed"] == nil)
    }
}

/// A settings file read back from the JSON object a test took a key out of
/// or put one into; `JSONObjectFixture.object(encoding:)` makes the object.
enum WeirSettingsJSON {
    static func decode(_ object: [String: Any]) throws -> WeirSettings {
        try JSONDecoder().decode(WeirSettings.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
