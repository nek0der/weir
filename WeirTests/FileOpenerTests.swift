// FileOpenerTests.swift
// Weir — verifies the shared file-app preference and how each known editor
// is asked to open a file at a line.

import Foundation
import Testing
@testable import Weir

struct FileOpenerTests {
    private let application = FileApplication(
        bundleIdentifier: "com.example.Editor",
        lastKnownDisplayName: "Example Editor"
    )

    @Test("An unset app leaves file handling to macOS")
    func application_unsetUsesMacOSDefault() {
        let resolution = FileOpener.application(for: nil) { identifier in
            Issue.record("An unset app looked up \(identifier)")
            return nil
        }

        #expect(resolution == .macOSDefault)
        #expect(resolution.displayName == nil)
    }

    @Test("A configured bundle identifier is resolved when the action runs")
    func application_configuredResolvesBundleIdentifier() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Example Editor.app")
        let resolution = FileOpener.application(for: application) { identifier in
            #expect(identifier == "com.example.Editor")
            return bundleURL
        }

        #expect(resolution == .configured(application, bundleURL: bundleURL))
        #expect(resolution.displayName == "Example Editor")
    }

    @Test("A missing app preserves its last-known name and remains distinguishable")
    func application_missingKeepsPreference() {
        let resolution = FileOpener.application(for: application) { _ in nil }

        #expect(resolution == .configuredApplicationMissing(application))
        #expect(resolution.displayName == "Example Editor")
    }

    @Test("A future app preference field survives a read and write")
    func application_unknownFieldsRoundTrip() throws {
        let data = Data(#"{"bundleIdentifier":"com.example.Editor","lastKnownDisplayName":"Example Editor","future":"value"}"#.utf8)

        let decoded = try JSONDecoder().decode(FileApplication.self, from: data)
        let encoded = try JSONEncoder().encode(decoded)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["bundleIdentifier"] as? String == "com.example.Editor")
        #expect(object["lastKnownDisplayName"] as? String == "Example Editor")
        #expect(object["future"] as? String == "value")
    }

    // MARK: - Line launches

    private let file = URL(fileURLWithPath: "/Users/me/My Project/Sources/Main.swift")
    private let appURL = URL(fileURLWithPath: "/Applications/Editor.app")

    private func launch(_ bundleIdentifier: String, _ position: FilePosition) -> EditorLineLaunch? {
        EditorLineLaunch.make(bundleIdentifier: bundleIdentifier, applicationURL: appURL, file: file, position: position)
    }

    @Test(arguments: [
        ("com.microsoft.VSCode", "vscode", 5),
        ("com.microsoft.VSCode", "vscode", nil),
        ("com.microsoft.VSCodeInsiders", "vscode-insiders", 5),
        ("com.microsoft.VSCodeInsiders", "vscode-insiders", nil)
    ])
    func vsCodeUsesItsEditionSchemeAndOnlySuppliedCoordinates(bundleIdentifier: String, scheme: String, column: Int?) throws {
        let coordinate = column.map { "12:\($0)" } ?? "12"
        let expected = try #require(URL(string: "\(scheme)://file/Users/me/My%20Project/Sources/Main.swift:\(coordinate)"))
        #expect(launch(bundleIdentifier, FilePosition(line: 12, column: column)) == .url(expected))
    }

    @Test func xcodeUsesXedWithTheLineOnly() {
        #expect(
            launch("com.apple.dt.Xcode", FilePosition(line: 12, column: 5))
                == .process(executable: URL(fileURLWithPath: "/usr/bin/xed"), arguments: ["--line", "12", file.path])
        )
    }

    /// The path goes in one argument, so a space cannot split it.
    @Test func zedUsesTheCLIInsideItsBundle() {
        #expect(
            launch("dev.zed.Zed", FilePosition(line: 3, column: nil))
                == .process(
                    executable: appURL.appendingPathComponent("Contents/MacOS/cli"),
                    arguments: [file.path + ":3"]
                )
        )
    }

    @Test func unknownEditorHasNoLineLaunch() {
        #expect(launch("com.example.Unknown", FilePosition(line: 1, column: nil)) == nil)
    }
}
