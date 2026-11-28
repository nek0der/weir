// TerminalThemeConfigTests.swift
// Weir — covers the `theme` line and color-only theme copies Weir writes, and the palettes read back from libghostty.

import Foundation
import GhosttyKit
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Terminal theme config")
@MainActor
struct TerminalThemeConfigTests {
    /// The repository's bundled Ghostty resources, so the read-back sees the
    /// real theme files without depending on the test host's bundle.
    private static let resourcesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Weir/Resources/ghostty").path

    private func themeLine(_ config: String) -> String? {
        config.split(separator: "\n").first { $0.hasPrefix("theme = ") }.map(String.init)
    }

    private static let processID: Int32 = 4242

    private func userCatalog(_ user: URL) -> TerminalThemeCatalog {
        TerminalThemeCatalog(bundledDirectory: nil, userDirectory: user, ghosttyDirectories: [])
    }

    private func writeTheme(_ text: String, named name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// The copy Weir names for `text` on `side` under `directory`.
    private func copyPath(
        _ text: String,
        side: TerminalThemeBrightness = .dark,
        in directory: URL,
        processID: Int32 = Self.processID
    ) throws -> String {
        let colors = try #require(TerminalThemeFile.sanitized(text))
        return GhosttyConfigBridge.themeCopyPath(
            for: side, colors: colors, directory: directory.path, processID: processID
        )
    }

    /// The names in `directory` that start with this suite's copy prefix.
    private func copyNames(in directory: URL, processID: Int32 = Self.processID) throws -> [String] {
        let prefix = GhosttyConfigBridge.themeCopyPrefix(processID: processID)
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(prefix) }.sorted()
    }

    private func settings(dark: TerminalThemeRef? = nil, light: TerminalThemeRef? = nil) -> WeirSettings {
        var settings = WeirSettings.default
        settings.appearance.terminalTheme = TerminalThemeSelection(light: light, dark: dark)
        return settings
    }

    @Test func aUserChoiceIsNamedByWeirsCopy() throws {
        try withTempDir { root in
            let user = root.appendingPathComponent("themes")
            try writeTheme("background = #000000\n", named: "Night", in: user)
            let settings = settings(dark: TerminalThemeRef(name: "Night", origin: .user))

            let config = GhosttyConfigBridge.makeConfigString(
                settings: settings,
                resourcesDir: "/res",
                themeCatalog: userCatalog(user),
                themeDirectory: root,
                processID: Self.processID
            )
            let copy = try copyPath("background = #000000\n", in: root)
            #expect(themeLine(config) == "theme = light:/res/themes/Apple System Colors Light,dark:\(copy)")
            // Building the string writes nothing.
            #expect(!FileManager.default.fileExists(atPath: copy))
            let theme = GhosttyConfigBridge.resolveTheme(
                selection: settings.appearance.terminalTheme, resourcesDir: "/res", catalog: userCatalog(user)
            )
            #expect(theme?.fallbacks.isEmpty == true)
        }
    }

    @Test func theWrittenCopyHoldsOnlyTheThemesColors() throws {
        try withTempDir { root in
            let user = root.appendingPathComponent("themes")
            try writeTheme(
                "command = /bin/echo hijacked\ninitial-command = /usr/bin/true\nbackground = #102030\npalette = 1=#ff0000\n",
                named: "Hostile",
                in: user
            )
            let settings = settings(dark: TerminalThemeRef(name: "Hostile", origin: .user))
            let output = root.appendingPathComponent("out")

            let path = try #require(GhosttyConfigBridge.writeConfigFile(
                settings: settings,
                resourcesDir: Self.resourcesDir,
                directory: output,
                processID: Self.processID,
                themeCatalog: userCatalog(user)
            ))
            let copy = GhosttyConfigBridge.themeCopyPath(
                for: .dark,
                colors: "background = #102030\npalette = 1=#ff0000\n",
                directory: output.path,
                processID: Self.processID
            )
            #expect(try String(contentsOfFile: copy, encoding: .utf8) == "background = #102030\npalette = 1=#ff0000\n")
            let config = try String(contentsOfFile: path, encoding: .utf8)
            #expect(!config.contains("hijacked"))
            #expect(themeLine(config) == "theme = light:\(Self.resourcesDir)/themes/Apple System Colors Light,dark:\(copy)")
            #expect(GhosttyConfigBridge.writtenThemePaths?.dark == copy)
            // The light side is bundled and needs no copy.
            #expect(try copyNames(in: output) == [(copy as NSString).lastPathComponent])
            let diagnostics = try #require(GhosttyConfigBridge.configDiagnostics(at: path))
            #expect(diagnostics.isEmpty)
        }
    }

    @Test func aMissingChoiceFallsBackToTheDefaultAndIsReported() throws {
        try withTempDir { root in
            let missing = TerminalThemeRef(name: "Gone", origin: .user)
            let settings = settings(light: missing)

            let chosen = GhosttyConfigBridge.makeConfigString(
                settings: settings, resourcesDir: "/res", themeCatalog: userCatalog(root)
            )
            let standard = GhosttyConfigBridge.makeConfigString(settings: .default, resourcesDir: "/res")
            #expect(chosen == standard)
            let theme = GhosttyConfigBridge.resolveTheme(
                selection: settings.appearance.terminalTheme, resourcesDir: "/res", catalog: userCatalog(root)
            )
            #expect(theme?.fallbacks == [.light: missing])
        }
    }

    @Test(arguments: ["no-background", "too-large", "not-utf8"])
    func aFileThatCannotBeUsedFallsBackToTheDefault(_ kind: String) throws {
        try withTempDir { root in
            let file = root.appendingPathComponent("Theme")
            switch kind {
            case "no-background":
                try "foreground = #ffffff\ncommand = /bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
            case "too-large":
                let padding = String(repeating: "#", count: TerminalThemeFile.maxBytes)
                try "background = #000000\n\(padding)\n".write(to: file, atomically: true, encoding: .utf8)
            default:
                try Data([0x62, 0x61, 0xFF, 0xFE, 0x0A]).write(to: file)
            }
            let ref = TerminalThemeRef(name: "Theme", origin: .user)
            let theme = try #require(GhosttyConfigBridge.resolveTheme(
                selection: TerminalThemeSelection(dark: ref), resourcesDir: "/res", catalog: userCatalog(root)
            ))
            #expect(theme.dark == .bundled(path: "/res/themes/Apple System Colors"))
            #expect(theme.fallbacks == [.dark: ref])
        }
    }

    // MARK: - Copy names

    @Test func aCopyIsNamedByItsProcessSideAndColors() {
        let name = (GhosttyConfigBridge.themeCopyPath(
            for: .dark, colors: "background = #000000\n", directory: "/tmp", processID: 42
        ) as NSString).lastPathComponent
        #expect(name.wholeMatch(of: /ghostty-theme-42-dark-[0-9a-f]{16}\.weir/) != nil)
        let same = GhosttyConfigBridge.themeCopyPath(
            for: .dark, colors: "background = #000000\n", directory: "/tmp", processID: 42
        )
        let other = GhosttyConfigBridge.themeCopyPath(
            for: .dark, colors: "background = #000001\n", directory: "/tmp", processID: 42
        )
        #expect(same == "/tmp/" + name)
        #expect(other != same)
    }

    @Test func aReloadSkipsOnlyWhenTheThemesColorsAreUnchanged() throws {
        try withTempDir { root in
            try writeTheme("background = #000000\n", named: "A", in: root)
            try writeTheme("background = #222222\n", named: "B", in: root)
            let first = settings(dark: TerminalThemeRef(name: "A", origin: .user))
            let second = settings(dark: TerminalThemeRef(name: "B", origin: .user))
            @MainActor func config(_ settings: WeirSettings) -> String {
                GhosttyConfigBridge.makeConfigString(settings: settings, resourcesDir: "/res", themeCatalog: userCatalog(root))
            }

            let original = config(first)
            #expect(config(first) == original)
            #expect(config(second) != original)
            try writeTheme("background = #000000\nforeground = #ffffff\n", named: "A", in: root)
            #expect(config(first) != original)
        }
    }

    @Test func anExistingCopyIsNeverRewritten() throws {
        try withTempDir { root in
            let user = root.appendingPathComponent("themes")
            let output = root.appendingPathComponent("out")
            try writeTheme("background = #000000\n", named: "A", in: user)
            try writeTheme("background = #222222\n", named: "B", in: user)
            @MainActor func write(_ name: String) throws {
                _ = try #require(GhosttyConfigBridge.writeConfigFile(
                    settings: settings(dark: TerminalThemeRef(name: name, origin: .user)),
                    resourcesDir: "/res",
                    directory: output,
                    processID: Self.processID,
                    themeCatalog: userCatalog(user)
                ))
            }

            try write("A")
            let copyA = try copyPath("background = #000000\n", in: output)
            let past = Date(timeIntervalSince1970: 1_000_000_000)
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: copyA)
            try write("A")
            let attributes = try FileManager.default.attributesOfItem(atPath: copyA)
            #expect(attributes[.modificationDate] as? Date == past)

            // Another theme gets its own copy, and A's keeps its colors.
            try write("B")
            let copyB = try copyPath("background = #222222\n", in: output)
            #expect(try String(contentsOfFile: copyA, encoding: .utf8) == "background = #000000\n")
            #expect(try String(contentsOfFile: copyB, encoding: .utf8) == "background = #222222\n")
        }
    }

    @Test func cleanupRemovesUnnamedCopiesAndThoseOfExitedProcesses() throws {
        try withTempDir { root in
            let kept = GhosttyConfigBridge.themeCopyPath(
                for: .light, colors: "background = #000000\n", directory: root.path, processID: 42
            )
            let stale = GhosttyConfigBridge.themeCopyPath(
                for: .dark, colors: "background = #111111\n", directory: root.path, processID: 42
            )
            // 4242 is running, 4343 has exited; the probe and the config
            // are not copies, whatever process wrote them.
            let exited = root.appendingPathComponent("ghostty-theme-4343-dark-0123456789abcdef.weir").path
            let others = [
                "ghostty-theme-4242-dark-0123456789abcdef.weir",
                "ghostty-theme-probe-4343-dark.weir",
                "ghostty-config-4343.weir"
            ]
            for path in [kept, stale, exited] + others.map({ root.appendingPathComponent($0).path }) {
                try "background = #000000\n".write(toFile: path, atomically: true, encoding: .utf8)
            }

            GhosttyConfigBridge.removeStaleThemeCopies(
                keeping: GhosttyConfigBridge.TerminalThemePaths(light: kept, dark: "/res/themes/Apple System Colors"),
                directory: root,
                processID: 42,
                isAlive: { $0 == 4242 }
            )
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            #expect(names == ([(kept as NSString).lastPathComponent] + others).sorted())
        }
    }

    @Test func aCopyIsKeptOutOfTheTemporaryFolder() {
        let copies = GhosttyConfigBridge.themeCopyDirectory
        #expect(!copies.hasPrefix(GhosttyConfigBridge.temporaryDirectory))
        #expect(copies.hasPrefix(WeirPaths.applicationSupportDirectory().path))
    }

    @Test func aFailedReloadKeepsTheCopyTheRunningConfigNames() throws {
        try withTempDir { root in
            let user = root.appendingPathComponent("themes")
            let output = root.appendingPathComponent("out")
            try writeTheme("background = #000000\n", named: "A", in: user)
            try writeTheme("background = #222222\n", named: "B", in: user)
            let pid = ProcessInfo.processInfo.processIdentifier
            @MainActor func reload(_ name: String) throws(GhosttyConfigReloadError) {
                _ = try GhosttyConfigBridge.reloadConfig(
                    settings: settings(dark: TerminalThemeRef(name: name, origin: .user)),
                    resourcesDir: Self.resourcesDir,
                    includeUserConfig: false,
                    directory: output,
                    themeCatalog: userCatalog(user)
                ) { ghostty_config_free($0) }
            }
            let copyA = try copyPath("background = #000000\n", in: output, processID: pid)
            let copyB = try copyPath("background = #222222\n", in: output, processID: pid)

            try reload("A")
            #expect(try copyNames(in: output, processID: pid) == [(copyA as NSString).lastPathComponent])

            // A folder in place of the config file makes the next write fail
            // after B's copy is written.
            let config = output.appendingPathComponent("ghostty-config-\(pid).weir")
            try FileManager.default.removeItem(at: config)
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
            #expect(throws: GhosttyConfigReloadError.layerWriteFailed) { try reload("B") }
            #expect(try String(contentsOfFile: copyA, encoding: .utf8) == "background = #000000\n")

            try FileManager.default.removeItem(at: config)
            try reload("B")
            #expect(try copyNames(in: output, processID: pid) == [(copyB as NSString).lastPathComponent])
        }
    }

    // MARK: - Quoting

    @Test func aPathIsQuotedOnlyWhenTheLineNeedsIt() {
        let plain = "/Applications/Weir.app/Contents/Resources/ghostty/themes/Apple System Colors"
        #expect(GhosttyConfigBridge.themeLineValue(plain) == plain)
        #expect(GhosttyConfigBridge.themeLineValue("/Beta, QA/x") == #""/Beta, QA/x""#)
        #expect(GhosttyConfigBridge.themeLineValue(#"/a"b\c"#) == #""/a\"b\\c""#)
        #expect(GhosttyConfigBridge.themeLineValue("/a/b ") == #""/a/b ""#)
        #expect(GhosttyConfigBridge.themeLineValue("/a\nb") == nil)
        #expect(GhosttyConfigBridge.themeLine(light: "/a", dark: "/a\rb") == nil)
    }

    /// Copies the bundled default pair into `folder`'s `themes` folder, so
    /// `folder` can stand as a resources folder.
    private func makeResources(in folder: URL) throws -> String {
        let themes = folder.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        for side in [TerminalThemeBrightness.light, .dark] {
            let name = GhosttyConfigBridge.defaultThemeRef(for: side).name
            try FileManager.default.copyItem(
                atPath: GhosttyConfigBridge.defaultThemePath(for: side, resourcesDir: Self.resourcesDir),
                toPath: themes.appendingPathComponent(name).path
            )
        }
        return folder.path
    }

    /// The `background` libghostty finalizes from the config at `path`.
    private func finalizedBackground(ofConfigAt path: String) throws -> RGB8 {
        let cfg = try #require(GhosttyConfigBridge.makeConfig(path: path, includeUserConfig: false))
        defer { ghostty_config_free(cfg) }
        var value = ghostty_config_color_s()
        let key = "background"
        let isRead = key.withCString { ghostty_config_get(cfg, &value, $0, UInt(key.utf8.count)) }
        try #require(isRead)
        return RGB8(r: value.r, g: value.g, b: value.b)
    }

    @Test func aFolderWithACommaReachesLibghosttyWhole() throws {
        try withTempDir { root in
            let folder = root.appendingPathComponent("Beta, QA")
            let resources = try makeResources(in: folder.appendingPathComponent("ghostty"))
            let user = folder.appendingPathComponent("themes")
            try writeTheme("background = #102030\n", named: "Paper", in: user)

            // The default pair, from a resources folder with a comma.
            let standard = try #require(GhosttyConfigBridge.writeConfigFile(
                settings: .default, resourcesDir: resources, directory: folder, processID: Self.processID
            ))
            #expect(GhosttyConfigBridge.configDiagnostics(at: standard) == [])
            #expect(try finalizedBackground(ofConfigAt: standard) == RGB8(r: 0xFE, g: 0xFF, b: 0xFF))

            // A chosen theme on the side a finalized config loads, whose copy
            // is written to the folder with the comma.
            let chosen = try #require(GhosttyConfigBridge.writeConfigFile(
                settings: settings(light: TerminalThemeRef(name: "Paper", origin: .user)),
                resourcesDir: resources,
                directory: folder,
                processID: Self.processID,
                themeCatalog: userCatalog(user)
            ))
            let copy = try copyPath("background = #102030\n", side: .light, in: folder)
            #expect(try themeLine(String(contentsOfFile: chosen, encoding: .utf8))?.contains("light:\"\(copy)\",dark:\"") == true)
            #expect(GhosttyConfigBridge.configDiagnostics(at: chosen) == [])
            #expect(try finalizedBackground(ofConfigAt: chosen) == RGB8(r: 0x10, g: 0x20, b: 0x30))

            // The probes write their line the same way.
            let palettes = GhosttyConfigBridge.readBackPalettes(
                themePaths: GhosttyConfigBridge.writtenThemePaths,
                includeUserConfig: false,
                directory: folder
            )
            #expect(palettes.light?.background == RGB8(r: 0x10, g: 0x20, b: 0x30))
            #expect(palettes.dark?.background == RGB8(r: 0x1E, g: 0x1E, b: 0x1E))
        }
    }

    @Test func theDefaultPairReadsBackTheBundledColors() throws {
        try withTempDir { directory in
            let palettes = GhosttyConfigBridge.readBackPalettes(
                themePaths: GhosttyConfigBridge.defaultThemePaths(resourcesDir: Self.resourcesDir),
                includeUserConfig: false,
                directory: directory
            )
            let light = try #require(palettes.light)
            let dark = try #require(palettes.dark)
            #expect(light.background == RGB8(r: 0xFE, g: 0xFF, b: 0xFF))
            #expect(dark.background == RGB8(r: 0x1E, g: 0x1E, b: 0x1E))
            #expect(light.ansi.count == TerminalPalette.ansiCount)
            #expect(dark.ansi.count == TerminalPalette.ansiCount)
            #expect(light.foreground != dark.foreground)
            // The probes clean up after themselves.
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    /// Writes the config for a dark `Fixture` theme under `root` and returns
    /// the paths its `theme` line names.
    private func writeFixtureConfig(
        _ text: String,
        in root: URL
    ) throws -> GhosttyConfigBridge.TerminalThemePaths {
        let user = root.appendingPathComponent("themes")
        try writeTheme(text, named: "Fixture", in: user)
        let settings = settings(dark: TerminalThemeRef(name: "Fixture", origin: .user))
        let output = root.appendingPathComponent("out")
        _ = try #require(GhosttyConfigBridge.writeConfigFile(
            settings: settings,
            resourcesDir: Self.resourcesDir,
            directory: output,
            processID: Self.processID,
            themeCatalog: userCatalog(user)
        ))
        let theme = try #require(GhosttyConfigBridge.resolveTheme(
            selection: settings.appearance.terminalTheme, resourcesDir: Self.resourcesDir, catalog: userCatalog(user)
        ))
        return GhosttyConfigBridge.themePaths(for: theme, directory: output.path, processID: Self.processID)
    }

    @Test func aChosenThemeReadsBackItsWholePaletteFromTheCopy() throws {
        try withTempDir { root in
            let ansi = (0..<TerminalPalette.ansiCount).map { RGB8(r: UInt8($0 * 10), g: UInt8($0), b: 0x80) }
            let paletteLines = ansi.enumerated().map { index, color in
                "palette = \(index)=#" + String(format: "%02x%02x%02x", color.r, color.g, color.b)
            }
            let text = (["background = #102030", "foreground = #e0d0c0"] + paletteLines).joined(separator: "\n")
            let paths = try writeFixtureConfig(text, in: root)
            // A later edit to the theme file does not reach the read-back
            // until the config is written again.
            try writeTheme("background = #ffffff\n", named: "Fixture", in: root.appendingPathComponent("themes"))

            let palettes = GhosttyConfigBridge.readBackPalettes(
                themePaths: paths,
                includeUserConfig: false,
                directory: root
            )
            #expect(palettes.dark == TerminalPalette(
                background: RGB8(r: 0x10, g: 0x20, b: 0x30),
                foreground: RGB8(r: 0xE0, g: 0xD0, b: 0xC0),
                ansi: ansi
            ))
            #expect(palettes.light?.background == RGB8(r: 0xFE, g: 0xFF, b: 0xFF))
        }
    }

    @Test func aBackgroundInTheUserConfigBeatsTheTheme() throws {
        try withTempDir { root in
            let paths = try writeFixtureConfig("background = #102030\n", in: root)
            let userConfig = root.appendingPathComponent("user-config")
            try "background = #123456\n".write(to: userConfig, atomically: true, encoding: .utf8)

            let palettes = GhosttyConfigBridge.readBackPalettes(
                themePaths: paths,
                includeUserConfig: true,
                userConfigPath: userConfig.path,
                directory: root
            )
            #expect(palettes.dark?.background == RGB8(r: 0x12, g: 0x34, b: 0x56))
            #expect(palettes.light?.background == RGB8(r: 0x12, g: 0x34, b: 0x56))
        }
    }

    @Test func aProbeDoesNotRecordAReadOfTheUserConfig() throws {
        try withTempDir { directory in
            let userConfig = directory.appendingPathComponent("user-config")
            try "foreground = #ffffff\n".write(to: userConfig, atomically: true, encoding: .utf8)
            let before = GhosttyConfigBridge.userConfigReadAt
            _ = GhosttyConfigBridge.readBackPalettes(
                themePaths: GhosttyConfigBridge.defaultThemePaths(resourcesDir: Self.resourcesDir),
                includeUserConfig: true,
                userConfigPath: userConfig.path,
                directory: directory
            )
            #expect(GhosttyConfigBridge.userConfigReadAt == before)
        }
    }

    @Test func noResourcesFolderReadsNothing() {
        let palettes = GhosttyConfigBridge.readBackPalettes(
            themePaths: GhosttyConfigBridge.defaultThemePaths(resourcesDir: nil), includeUserConfig: false
        )
        #expect(palettes.light == nil)
        #expect(palettes.dark == nil)
    }

    @Test func theStoreBumpsItsRevisionOnlyOnChange() {
        let store = TerminalThemeStore()
        let dark = TerminalPalette(
            background: RGB8(r: 0x1E, g: 0x1E, b: 0x1E), foreground: RGB8(r: 0xFF, g: 0xFF, b: 0xFF), ansi: []
        )
        store.update(light: nil, dark: dark)
        store.update(light: nil, dark: dark)
        #expect(store.revision == 1)
        store.setBundledPalettes(light: nil, dark: dark)
        #expect(!store.paintsGround(for: .dark))
        var other = dark
        other.background = RGB8(r: 0, g: 0, b: 0)
        store.update(light: nil, dark: other)
        #expect(store.revision == 2)
        #expect(store.paintsGround(for: .dark))
        #expect(!store.paintsGround(for: .light))
    }
}
