// ReviewFileMenuModelTests.swift
// Weir — the items a reviewed file's path menu offers, in the rail and on the diff's header.

import AppKit
import Foundation
import Testing
@testable import Weir

struct ReviewFileMenuModelTests {
    private static let en = Locale(identifier: "en")
    private static let editor = FileApplication(bundleIdentifier: "com.example.Editor", lastKnownDisplayName: "Example Editor")

    private static func titles(_ items: [ReviewFileMenuItem]) -> [String] {
        items.map { $0.title.resolved(in: en) }
    }

    @Test func items_whenTheExistenceCheckFindsTheFile_offerEveryItem() throws {
        try withTempDir { root in
            let file = ReviewFile(path: "Sources/a.swift", layer: .unstaged, status: .modified)

            let items = ReviewFileMenuModel.items(for: file, in: root, application: .macOSDefault) { _ in true }

            #expect(Self.titles(items) == [
                "Copy Relative Path",
                "Copy Absolute Path",
                "Open in Default Application",
                "Show in Finder"
            ])
            #expect(items.map(\.action) == [
                .copyRelativePath("Sources/a.swift"),
                .copyAbsolutePath("Sources/a.swift", root: root),
                .open("Sources/a.swift", root: root),
                .reveal("Sources/a.swift", root: root)
            ])
        }
    }

    /// The open item names the app Settings chose.
    @Test func items_withAChosenApplication_nameItOnTheOpenItem() throws {
        try withTempDir { root in
            let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
            let application = FileApplicationResolution.configured(
                Self.editor,
                bundleURL: URL(fileURLWithPath: "/Applications/Example Editor.app")
            )

            let items = ReviewFileMenuModel.items(for: file, in: root, application: application) { _ in true }

            #expect(Self.titles(items)[2] == "Open in Example Editor")
            #expect(items[2].action != nil)
        }
    }

    /// A deleted file cannot be opened, but its path can still be copied,
    /// and Finder shows where it was.
    @Test func items_whenTheExistenceCheckFindsNoFile_cannotOpenIt() throws {
        try withTempDir { root in
            let file = ReviewFile(path: "gone.swift", layer: .unstaged, status: .deleted)

            let items = ReviewFileMenuModel.items(for: file, in: root, application: .macOSDefault) { _ in false }

            #expect(items.map { $0.action != nil } == [true, true, false, true])
        }
    }

    /// A name that is not UTF-8 names no file: every item shows, and none
    /// can be chosen, in the rail and on the diff's header, whose menu
    /// items then have no action to run and show dimmed.
    @MainActor
    @Test func aNameThatIsNotUTF8_showsEveryItemDisabled_inBothMenus() throws {
        try withTempDir { root in
            let file = ReviewFile(path: "caf?.txt", layer: .untracked, status: .untracked, isNameUndecodable: true)

            let items = ReviewFileMenuModel.items(for: file, in: root, application: .macOSDefault) { _ in true }
            let header = ReviewMenuItem.items(from: items, locale: Self.en) { _ in }

            #expect(items.count == 4)
            #expect(items.allSatisfy { $0.action == nil })
            #expect(header.map(\.title) == Self.titles(items))
            #expect(header.allSatisfy { !$0.isEnabled && $0.action == nil })
        }
    }

    /// The header turns a choosable item into an enabled one that runs it.
    @MainActor
    @Test func theHeadersItems_runTheModelsActions() throws {
        try withTempDir { root in
            let file = ReviewFile(path: "gone.swift", layer: .unstaged, status: .deleted)
            let items = ReviewFileMenuModel.items(for: file, in: root, application: .macOSDefault) { _ in false }
            var ran: [ReviewFileMenuItem.Action] = []

            let header = ReviewMenuItem.items(from: items, locale: Self.en) { ran.append($0) }
            for item in header where item.isEnabled {
                if let action = item.action {
                    NSApplication.shared.sendAction(action, to: item.target, from: item)
                }
            }

            #expect(header.map(\.isEnabled) == [true, true, false, true])
            #expect(header.map { $0.action != nil } == [true, true, false, true])
            #expect(ran == items.compactMap(\.action))
        }
    }

    /// The path is checked again when the item is chosen: a file replaced
    /// by a link out of the repository after the menu was drawn is left
    /// alone.
    @Test func anAction_resolvesItsPathAgain_whenChosen() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("repo")
            let outside = dir.appendingPathComponent("outside.txt")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data().write(to: outside)
            let fileURL = root.appendingPathComponent("a.txt")
            try Data().write(to: fileURL)
            let file = ReviewFile(path: "a.txt", layer: .unstaged, status: .modified)
            let items = ReviewFileMenuModel.items(for: file, in: root, application: .macOSDefault)
            let open = try #require(items[2].action)
            #expect(open.fileURL() != nil)

            try FileManager.default.removeItem(at: fileURL)
            try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: outside)

            #expect(open.fileURL() == nil)
            #expect(items.compactMap(\.action).allSatisfy { action in
                if case .copyRelativePath = action {
                    return true
                }
                return action.fileURL() == nil
            })
        }
    }
}
