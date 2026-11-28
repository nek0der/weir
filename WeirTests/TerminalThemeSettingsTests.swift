// TerminalThemeSettingsTests.swift
// Weir — covers how `settings.json` stores the terminal theme choice.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Terminal theme settings")
struct TerminalThemeSettingsTests {
    private func appearance(_ json: String) throws -> AppearanceSettings {
        try JSONDecoder().decode(AppearanceSettings.self, from: Data(json.utf8))
    }

    @Test func theDefaultSelectionIsWrittenAsAnEmptyObject() throws {
        let object = try JSONObjectFixture.object(JSONEncoder().encode(AppearanceSettings()))
        let theme = try #require(object["terminalTheme"] as? [String: Any])
        #expect(theme.isEmpty)
        #expect(AppearanceSettings().terminalTheme == TerminalThemeSelection())
    }

    @Test func aChosenPairRoundTrips() throws {
        var settings = AppearanceSettings()
        settings.terminalTheme = TerminalThemeSelection(
            light: TerminalThemeRef(name: "Solarized Light", origin: .user),
            dark: TerminalThemeRef(name: "Apple System Colors", origin: .bundled)
        )
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: data) == settings)
        let theme = try #require(JSONObjectFixture.object(data)["terminalTheme"] as? [String: Any])
        let light = try #require(theme["light"] as? [String: Any])
        #expect(light["origin"] as? String == "user")
        #expect(light["name"] as? String == "Solarized Light")
    }

    @Test func anUnknownOriginReadsAsNoChoiceAndIsWrittenBack() throws {
        let decoded = try appearance("""
        {"terminalTheme":{"light":{"name":"Ocean","origin":"cloud"},
                          "dark":{"name":"Night","origin":"ghostty"},
                          "source":"follow-app"}}
        """)
        #expect(decoded.terminalTheme.light == nil)
        #expect(decoded.terminalTheme.dark == TerminalThemeRef(name: "Night", origin: .ghostty))

        let written = try JSONObjectFixture.object(JSONEncoder().encode(decoded))
        let theme = try #require(written["terminalTheme"] as? [String: Any])
        let light = try #require(theme["light"] as? [String: Any])
        #expect(light["origin"] as? String == "cloud")
        #expect(theme["source"] as? String == "follow-app")
    }

    @Test func choosingASideReplacesTheValueThisBuildCouldNotRead() throws {
        var decoded = try appearance(#"{"terminalTheme":{"light":{"name":"Ocean","origin":"cloud"}}}"#)
        decoded.terminalTheme.light = TerminalThemeRef(name: "Paper", origin: .user)
        let again = try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(decoded))
        #expect(again.terminalTheme.light == TerminalThemeRef(name: "Paper", origin: .user))
        #expect(again.terminalTheme.unreadableSides.isEmpty)
    }

    @Test func choosingTheDefaultAfterAThemeLeavesNoSideBehind() throws {
        var decoded = try appearance(#"{"terminalTheme":{"light":{"name":"Ocean","origin":"cloud"}}}"#)
        decoded.terminalTheme.choose(TerminalThemeRef(name: "Paper", origin: .user), for: .light)
        #expect(decoded.terminalTheme.unreadableSides.isEmpty)
        decoded.terminalTheme.choose(nil, for: .light)

        let written = try JSONObjectFixture.object(JSONEncoder().encode(decoded))
        let theme = try #require(written["terminalTheme"] as? [String: Any])
        #expect(theme.isEmpty)
        #expect(decoded.terminalTheme.isDefault)
    }

    @Test func choosingTheDefaultDropsAValueThisBuildCouldNotRead() throws {
        var decoded = try appearance(#"{"terminalTheme":{"dark":{"name":"Ocean","origin":"cloud"}}}"#)
        decoded.terminalTheme.choose(nil, for: .dark)
        let written = try JSONObjectFixture.object(JSONEncoder().encode(decoded))
        let theme = try #require(written["terminalTheme"] as? [String: Any])
        #expect(theme["dark"] == nil)
    }

    @Test func theScopeIsLeftOutUntilChosenAndRoundTrips() throws {
        var settings = AppearanceSettings()
        #expect(settings.terminalTheme.scope == .terminal)
        settings.terminalTheme.scope = .window
        let data = try JSONEncoder().encode(settings)
        let theme = try #require(JSONObjectFixture.object(data)["terminalTheme"] as? [String: Any])
        #expect(theme["scope"] as? String == "window")
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: data).terminalTheme.scope == .window)

        settings.terminalTheme.scope = .terminal
        let back = try JSONObjectFixture.object(JSONEncoder().encode(settings))
        #expect((back["terminalTheme"] as? [String: Any])?.isEmpty == true)
        #expect(settings.terminalTheme.isDefault)
    }

    @Test func anUnknownScopeReadsAsTheTerminalAndIsWrittenBack() throws {
        let decoded = try appearance(#"{"terminalTheme":{"scope":"everything"}}"#)
        #expect(decoded.terminalTheme.scope == .terminal)
        let written = try JSONObjectFixture.object(JSONEncoder().encode(decoded))
        let theme = try #require(written["terminalTheme"] as? [String: Any])
        #expect(theme["scope"] as? String == "everything")

        let notAString = try appearance(#"{"terminalTheme":{"scope":3}}"#)
        #expect(notAString.terminalTheme.scope == .terminal)
        #expect(notAString.terminalTheme.isDefault)
    }

    @Test func aMalformedThemeFallsBackWithoutLosingTheSection() throws {
        let decoded = try appearance(#"{"accentColor":"blue","terminalTheme":"dark"}"#)
        #expect(decoded.accentColor == .blue)
        #expect(decoded.terminalTheme.isDefault)
    }
}
