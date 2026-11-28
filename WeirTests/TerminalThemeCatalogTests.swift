// TerminalThemeCatalogTests.swift
// Weir — covers listing theme folders and resolving a chosen theme to its file.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Terminal theme catalog")
struct TerminalThemeCatalogTests {
    private func write(_ text: String, named name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test func listsUsableFilesSortedAndClassified() throws {
        try withTempDir { root in
            let user = root.appendingPathComponent("user")
            try write("background = #fdf6e3\n", named: "Solarized Light", in: user)
            try write("background = #002b36\n", named: "Solarized Dark", in: user)
            try write("foreground = #ffffff\n", named: "No Ground", in: user)
            try write("background = #000000\n", named: ".hidden", in: user)
            try write("background = #000000\n", named: "Bad, Name", in: user)
            try FileManager.default.createDirectory(
                at: user.appendingPathComponent("Folder"), withIntermediateDirectories: true
            )
            let catalog = TerminalThemeCatalog(
                bundledDirectory: nil,
                userDirectory: user,
                ghosttyDirectories: [root.appendingPathComponent("missing")]
            )

            let entries = catalog.entries()
            #expect(entries.map(\.ref.name) == ["No Ground", "Solarized Dark", "Solarized Light"])
            #expect(entries.allSatisfy { $0.ref.origin == .user })
            #expect(entries.map(\.brightness) == [nil, .dark, .light])
            #expect(entries[2].path == user.appendingPathComponent("Solarized Light").path)
        }
    }

    @Test func resolvesAChosenFileAndRefusesOneThatCannotBeUsed() throws {
        try withTempDir { root in
            let user = root.appendingPathComponent("user")
            try write("background = #000000\n", named: "Night", in: user)
            try write("background = #000000\n", named: "Outside", in: root)
            let catalog = TerminalThemeCatalog(bundledDirectory: nil, userDirectory: user, ghosttyDirectories: [])

            #expect(catalog.resolve(TerminalThemeRef(name: "Night", origin: .user))
                == user.appendingPathComponent("Night").path)
            #expect(catalog.resolve(TerminalThemeRef(name: "Gone", origin: .user)) == nil)
            #expect(catalog.resolve(TerminalThemeRef(name: "../Outside", origin: .user)) == nil)
            #expect(catalog.resolve(TerminalThemeRef(name: "..", origin: .user)) == nil)
            #expect(catalog.resolve(TerminalThemeRef(name: "Night", origin: .ghostty)) == nil)
            #expect(!TerminalThemeCatalog.isUsableName(" Night"))
            #expect(!TerminalThemeCatalog.isUsableName("Night "))
            #expect(TerminalThemeCatalog.isUsableName("Night Sky"))
        }
    }

    @Test func theUserFolderFollowsXDGConfigHome() {
        let home = URL(fileURLWithPath: "/home/someone", isDirectory: true)
        let xdg = TerminalThemeCatalog(
            resourcesDir: "/res", environment: ["XDG_CONFIG_HOME": "/xdg"], homeDirectory: home
        )
        #expect(xdg.userDirectory?.path == "/xdg/ghostty/themes")
        #expect(xdg.bundledDirectory?.path == "/res/themes")
        let plain = TerminalThemeCatalog(resourcesDir: nil, environment: [:], homeDirectory: home)
        #expect(plain.userDirectory?.path == "/home/someone/.config/ghostty/themes")
        #expect(plain.bundledDirectory == nil)
    }
}
