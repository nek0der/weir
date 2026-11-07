// TerminalLinkPolicyTests.swift
// Weir — pins what a ⌘-clicked terminal link may do, so an OSC 8 target
// chosen by terminal output never reaches Launch Services unchecked and no
// click launches an application or script.

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Weir

@Suite("Terminal link policy")
struct TerminalLinkPolicyTests {

    // MARK: Web and mail

    @Test(arguments: [TerminalLinkSource.matchedText, .hyperlink])
    func webLinkWithHostOpens(source: TerminalLinkSource) throws {
        let url = try #require(URL(string: "https://example.com/a?b=c"))
        #expect(TerminalLinkPolicy.action(for: "https://example.com/a?b=c", source: source) == .open(url))
        #expect(TerminalLinkPolicy.action(for: "https:relative", source: source) == .reject(.invalidWebURL))
    }

    @Test(arguments: [TerminalLinkSource.matchedText, .hyperlink])
    func mailtoNeedsAnAddress(source: TerminalLinkSource) throws {
        let text = "mailto:a@example.com?subject=Review"
        let url = try #require(URL(string: text))
        #expect(TerminalLinkPolicy.action(for: text, source: source) == .open(url))
        for empty in ["mailto:", "mailto:?subject=Review"] {
            #expect(TerminalLinkPolicy.action(for: empty, source: source) == .reject(.malformed))
        }
    }

    // MARK: Custom schemes

    @Test(arguments: [TerminalLinkSource.matchedText, .hyperlink], [
        "ssh://host.example", "magnet:?xt=urn:btih:abc", "tel:+15555550100", "git://host.example/repo"
    ])
    func customSchemesAskBeforeDispatch(source: TerminalLinkSource, text: String) throws {
        let url = try #require(URL(string: text))
        #expect(TerminalLinkPolicy.action(for: text, source: source) == .confirm(url))
    }

    @Test func hyperlinkCustomSchemeAsksFirst() throws {
        let url = try #require(URL(string: "x-apple.systempreferences:com.apple.preference"))
        #expect(TerminalLinkPolicy.action(for: url.absoluteString, source: .hyperlink) == .confirm(url))
    }

    // MARK: Characters

    @Test(arguments: [TerminalLinkSource.matchedText, .hyperlink], [
        "https://example.com/\u{202E}gpj.exe", "https://exa\u{200B}mple.com", "https://example.com/\na",
        "https://example.com/\u{0085}a", "https://example.com/\u{2029}a"
    ])
    func invisibleOrLineBreakingCharactersAreRejected(source: TerminalLinkSource, text: String) {
        #expect(TerminalLinkPolicy.action(for: text, source: source) == .reject(.unsafeCharacters))
    }

    @Test func displayStringEscapesWhatWouldHideTheTarget() throws {
        let url = try #require(URL(string: "x-test:a%E2%80%AEb"))
        #expect(TerminalLinkPolicy.displayString(for: url) == "x-test:a%E2%80%AEb")
        try withTempDir { dir in
            let file = try makeFile("left\u{202E}middle\nright.txt", in: dir)
            let expected = dir.resolvingSymlinksInPath().path + "/left\\u{202E}middle\\u{A}right.txt"
            #expect(TerminalLinkPolicy.displayString(for: file) == expected)
        }
    }

    // MARK: Files

    @Test(arguments: [TerminalLinkSource.matchedText, .hyperlink])
    func regularFileOpens(source: TerminalLinkSource) throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("notes.txt")
            try Data("hi".utf8).write(to: file)
            let canonical = file.resolvingSymlinksInPath()
            #expect(TerminalLinkPolicy.action(for: file.absoluteString, source: source) == .openFile(canonical, nil))
            #expect(TerminalLinkPolicy.action(for: file.path, source: .matchedText) == .openFile(canonical, nil))
        }
    }

    @Test func directoryOpens() throws {
        try withTempDir { dir in
            #expect(TerminalLinkPolicy.fileAction(for: dir) == .open(dir.resolvingSymlinksInPath()))
        }
    }

    /// The core of the fix: neither source may launch something that runs
    /// code. Finder shows it instead.
    @Test(arguments: [TerminalLinkSource.matchedText, .hyperlink])
    func applicationBundleIsRevealedNotLaunched(source: TerminalLinkSource) throws {
        try withTempDir { dir in
            let app = dir.appendingPathComponent("Tool.app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            // Compare paths: a URL parsed from text gains a trailing slash
            // once it resolves to a directory, which `URL ==` distinguishes.
            let action = TerminalLinkPolicy.action(for: app.absoluteString, source: source)
            guard case let .reveal(url) = action else {
                Issue.record("expected reveal, got \(action)")
                return
            }
            #expect(url.path == app.resolvingSymlinksInPath().path)
        }
    }

    enum UnsafeFileCase: CaseIterable {
        case extensionOnly, scriptType, executableMode
    }

    @Test(arguments: UnsafeFileCase.allCases)
    func scriptsAndExecutablesAreRevealed(sample: UnsafeFileCase) throws {
        try withTempDir { dir in
            let name: String
            let permissions: Int
            switch sample {
            case .extensionOnly: name = "shortcut.url"
                permissions = 0o644
            case .scriptType: name = "run.sh"
                permissions = 0o644
            case .executableMode: name = "plain.txt"
                permissions = 0o755
            }
            let file = try makeFile(name, in: dir)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
            let values = try file.resourceValues(forKeys: [.isExecutableKey, .contentTypeKey, .isRegularFileKey])
            try #require(values.isRegularFile == true)
            try #require(values.isExecutable == (sample == .executableMode))
            if sample == .scriptType {
                try #require(values.contentType?.conforms(to: .script) == true)
            } else {
                let type = try #require(values.contentType)
                try #require(!type.conforms(to: .script) && !type.conforms(to: .executable) && !type.conforms(to: .application))
            }
            for source in [TerminalLinkSource.matchedText, .hyperlink] {
                #expect(TerminalLinkPolicy.action(for: file.absoluteString, source: source) == .reveal(file.resolvingSymlinksInPath()))
            }
        }
    }

    /// A harmless-looking name must not hide an executable target.
    @Test func symlinkIsJudgedByItsTarget() throws {
        try withTempDir { dir in
            let app = dir.appendingPathComponent("Real.app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            let link = dir.appendingPathComponent("readme.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
            #expect(TerminalLinkPolicy.fileAction(for: link) == .reveal(app.resolvingSymlinksInPath()))
        }
    }

    @Test func missingFileIsRejected() {
        #expect(
            TerminalLinkPolicy.action(for: "file:///nonexistent/weir-\(UUID().uuidString)", source: .hyperlink)
                == .reject(.missingFile)
        )
    }

    @Test(arguments: [TerminalLinkSource.matchedText, .hyperlink])
    func remoteFileHostIsRejected(source: TerminalLinkSource) throws {
        #expect(TerminalLinkPolicy.action(for: "file://server.example/etc/hosts", source: source) == .reject(.remoteFile))
        try withTempDir { dir in
            let file = try makeFile("local.txt", in: dir)
            var components = try #require(URLComponents(url: file, resolvingAgainstBaseURL: false))
            components.host = "localhost"
            let local = try #require(components.url)
            #expect(TerminalLinkPolicy.action(for: local.absoluteString, source: source) == .openFile(file.resolvingSymlinksInPath(), nil))
        }
    }

    @Test(arguments: [TerminalLinkSource.matchedText, .hyperlink], ["#x", "?x=1"])
    func fileURLWithFragmentOrQueryIsRejected(source: TerminalLinkSource, suffix: String) throws {
        try withTempDir { dir in
            let file = try makeFile("local.txt", in: dir)
            #expect(TerminalLinkPolicy.action(for: file.absoluteString + suffix, source: source) == .reject(.malformed))
        }
    }

    /// OSC 8 requires a URI; a bare path could be reinterpreted later.
    @Test func hyperlinkWithoutSchemeIsRejected() {
        #expect(TerminalLinkPolicy.action(for: "/etc/hosts", source: .hyperlink) == .reject(.malformed))
    }

    @Test func relativeMatchWithNowhereToLookIsRejected() throws {
        try withTempDir { dir in
            let file = try makeFile("src/present.swift", in: dir)
            let reference = "src/present.swift:12"
            #expect(TerminalLinkPolicy.action(for: reference, source: .matchedText) == .reject(.missingFile))
            #expect(TerminalLinkPolicy.action(for: reference, source: .matchedText, baseDirectories: [dir]) ==
                .openFile(file.resolvingSymlinksInPath(), FilePosition(line: 12, column: nil)))
        }
    }

    // MARK: Paths with a position

    /// What agents and compilers print: a path relative to the pane's
    /// directory with a line and column.
    @Test(arguments: [
        ("Sources/Main.swift:12:5", FilePosition(line: 12, column: 5)),
        ("Sources/Main.swift:12", FilePosition(line: 12, column: nil)),
        ("Sources/Main.swift#L12", FilePosition(line: 12, column: nil)),
        ("Sources/Main.swift#L12C5", FilePosition(line: 12, column: 5)),
        ("Sources/Main.swift#L12-L20", FilePosition(line: 12, column: nil))
    ])
    func relativePathWithPositionOpensAtThatPosition(text: String, position: FilePosition) throws {
        try withTempDir { dir in
            let file = try makeFile("Sources/Main.swift", in: dir)
            #expect(
                TerminalLinkPolicy.action(for: text, source: .matchedText, baseDirectories: [dir])
                    == .openFile(file.resolvingSymlinksInPath(), position)
            )
        }
    }

    @Test func absolutePathWithPositionOpensAtThatPosition() throws {
        try withTempDir { dir in
            let file = try makeFile("a.txt", in: dir)
            #expect(
                TerminalLinkPolicy.action(for: file.path + ":3", source: .matchedText)
                    == .openFile(file.resolvingSymlinksInPath(), FilePosition(line: 3, column: nil))
            )
        }
    }

    /// A file whose name really ends in `:12` is opened as named.
    @Test func literalNameWinsOverASuffix() throws {
        try withTempDir { dir in
            let file = try makeFile("notes:12", in: dir)
            _ = try makeFile("notes", in: dir)
            #expect(
                TerminalLinkPolicy.action(for: "notes:12", source: .matchedText, baseDirectories: [dir])
                    == .openFile(file.resolvingSymlinksInPath(), nil)
            )
        }
    }

    /// The first base that has the file wins, so the pane's own directory
    /// takes precedence over the container root.
    @Test func baseDirectoriesAreTriedInOrder() throws {
        try withTempDir { dir in
            let paneDir = dir.appendingPathComponent("pane")
            let rootDir = dir.appendingPathComponent("root")
            let inPane = try makeFile("x/a.swift", in: paneDir)
            _ = try makeFile("x/a.swift", in: rootDir)
            let onlyInRoot = try makeFile("y/b.swift", in: rootDir)
            #expect(
                TerminalLinkPolicy.action(for: "x/a.swift:1", source: .matchedText, baseDirectories: [paneDir, rootDir])
                    == .openFile(inPane.resolvingSymlinksInPath(), FilePosition(line: 1, column: nil))
            )
            #expect(
                TerminalLinkPolicy.action(for: "y/b.swift:1", source: .matchedText, baseDirectories: [paneDir, rootDir])
                    == .openFile(onlyInRoot.resolvingSymlinksInPath(), FilePosition(line: 1, column: nil))
            )
        }
    }

    /// A position never turns a script into something that opens.
    @Test func scriptWithPositionIsStillRevealed() throws {
        try withTempDir { dir in
            let file = try makeFile("run.command", in: dir)
            #expect(
                TerminalLinkPolicy.action(for: "run.command:1", source: .matchedText, baseDirectories: [dir])
                    == .reveal(file.resolvingSymlinksInPath())
            )
        }
    }

    @Test(arguments: ["a.swift:0", "a.swift:", "a.swift#L", "a.swift#Lx", "a.swift#L0", "a.swift:999999999999999999999999999"])
    func malformedSuffixIsNotAPosition(text: String) {
        #expect(TerminalPathReference.candidates(for: text) == [TerminalPathReference(path: text, position: nil)])
    }

    @Test(arguments: ["a.swift:12:0", "a.swift#L12C0", "a.swift:12:999999999999999999999999999"])
    func invalidColumnPreservesTheValidLine(text: String) {
        #expect(TerminalPathReference.candidates(for: text) == [
            TerminalPathReference(path: text, position: nil),
            TerminalPathReference(path: "a.swift", position: FilePosition(line: 12, column: nil))
        ])
    }

    private func makeFile(_ relativePath: String, in dir: URL) throws -> URL {
        try ScratchFile.write("x", to: relativePath, in: dir)
        return dir.appendingPathComponent(relativePath)
    }
}
