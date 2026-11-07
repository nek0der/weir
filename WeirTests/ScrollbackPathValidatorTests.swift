// ScrollbackPathValidatorTests.swift
// Weir — `ScrollbackFiles.validatedPath(_:)` is the gate
// between a freshly-restored `state.json` and libghostty's scrollback
// replay path. A tampered file could otherwise point at arbitrary
// targets (`~/.ssh/id_rsa`, `/etc/passwd`) and libghostty would
// happily read them into a pane, where an OSC 52 sequence could
// exfiltrate the contents.
//
// The validator only lets a path through when both:
//   - the extension is `.vt` (the format ghostty itself emits), and
//   - the path resolves under the scrollback folder the session was
//     handed (`WorkspaceSession.scrollbackFiles`).
//
// Anything else returns nil. The tests below pin that contract
// against the obvious exfiltration shapes, each in a folder of its own.

import Foundation
import Testing
@testable import Weir

struct ScrollbackPathValidatorTests {
    /// A `.vt` file path in the folder: the only shape the validator
    /// should accept.
    fileprivate static func sandboxedPath(_ files: ScrollbackFiles, name: String = "pane.vt") -> String {
        files.directory.appendingPathComponent(name).path
    }

    /// Runs `body` with a scrollback folder of its own, which exists,
    /// spelled as the validator hands a path on (`/var/…`, links followed).
    private func withFiles(_ body: (ScrollbackFiles) throws -> Void) throws {
        try withTempDir { dir in
            let directory = dir.appendingPathComponent("scrollback", isDirectory: true).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try body(ScrollbackFiles(directory: directory))
        }
    }

    @Test("a `.vt` file inside the scrollback sandbox passes through unchanged")
    func sandboxedVtFile_accepted() throws {
        try withFiles { files in
            let path = Self.sandboxedPath(files)
            #expect(files.validatedPath(path) == path)
        }
    }

    /// A path shape the validator turns away, built in the given folder.
    enum Rejected: CaseIterable, Sendable {
        /// Not `.vt`, though inside the sandbox.
        case otherExtension
        /// An absolute path outside the sandbox.
        case outside
        /// `<scrollback>/../leaked.vt`: the literal path starts with the
        /// sandbox prefix but `standardizedFileURL` pulls it back out, so
        /// the validator must follow that standardization rather than
        /// relying on the unresolved string.
        case parentTraversal
        /// `<scrollback>-evil/pane.vt` shares the sandbox's prefix
        /// character for character but lives in a sibling folder, so the
        /// comparison must include the trailing `/`.
        case prefixCollision
        /// A malformed path string, rejected without crashing.
        case empty

        func paths(in files: ScrollbackFiles) -> [String] {
            switch self {
            case .otherExtension:
                return [ScrollbackPathValidatorTests.sandboxedPath(files, name: "pane.txt")]
            case .outside:
                return ["/etc/passwd", ("~/.ssh/id_rsa" as NSString).expandingTildeInPath]
            case .parentTraversal:
                return [files.directory.appendingPathComponent("..").appendingPathComponent("leaked.vt").path]
            case .prefixCollision:
                var sandbox = files.directory.path
                while sandbox.hasSuffix("/") {
                    sandbox.removeLast()
                }
                return [sandbox + "-evil/pane.vt"]
            case .empty:
                return [""]
            }
        }
    }

    @Test(arguments: Rejected.allCases)
    func aPathShapeOutsideTheContract_isRejected(_ shape: Rejected) throws {
        try withFiles { files in
            for path in shape.paths(in: files) {
                #expect(files.validatedPath(path) == nil, "\(path)")
            }
        }
    }

    @Test("a leaf symlink is rejected even when its target is a valid scrollback file")
    func leafSymlinkToSandboxedVt_rejected() throws {
        try withFiles { files in
            let target = files.directory.appendingPathComponent("target.vt")
            let link = files.directory.appendingPathComponent("link.vt")
            try Data("scrollback".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            try #require(link.resolvingSymlinksInPath() == target)
            try #require(files.validatedPath(target.path) == target.path)

            #expect(files.validatedPath(link.path) == nil)
        }
    }

    @Test("a leaf symlink to an outside scrollback file is rejected")
    func symlinkOutsideSandbox_rejected() throws {
        try withFiles { files in
            let target = files.directory.deletingLastPathComponent().appendingPathComponent("outside.vt")
            let link = files.directory.appendingPathComponent("link.vt")
            try Data("scrollback".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            try #require(link.resolvingSymlinksInPath() == target)

            #expect(files.validatedPath(link.path) == nil)
        }
    }

    @Test("a normal scrollback leaf through a symlinked parent outside the sandbox is rejected")
    func symlinkedParentOutsideSandbox_rejected() throws {
        try withFiles { files in
            let fm = FileManager.default
            let outside = files.directory.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            let target = outside.appendingPathComponent("pane.vt")
            try Data("scrollback".utf8).write(to: target)
            let link = files.directory.appendingPathComponent("linked-parent")
            try fm.createSymbolicLink(at: link, withDestinationURL: outside)
            let linkedLeaf = link.appendingPathComponent("pane.vt")
            try #require(linkedLeaf.resolvingSymlinksInPath() == target)
            try #require(try linkedLeaf.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)

            #expect(files.validatedPath(linkedLeaf.path) == nil)
        }
    }
}
