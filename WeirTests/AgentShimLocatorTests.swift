// AgentShimLocatorTests.swift
// Weir — each agent's shim directory and variables, and the PATH order the pane's zsh puts the shims back in.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("AgentShimLocator")
struct AgentShimLocatorTests {
    /// The variable each agent's shim directory has always been exported in.
    private static func historicalShimVariable(_ kind: AgentKind) -> String {
        switch kind {
        case .claude: "WEIR_SHIM_DIR"
        case .codex: "WEIR_CODEX_SHIM_DIR"
        case .antigravity: "WEIR_ANTIGRAVITY_SHIM_DIR"
        case .opencode: "WEIR_OPENCODE_SHIM_DIR"
        }
    }

    @Test("every agent keeps the shim folder and variable it always had", arguments: AgentKind.allCases)
    func everyAgent_hasItsShim(kind: AgentKind) throws {
        let locator = AgentShimLocator(kind)
        #expect(locator.shimDirectoryVariable == Self.historicalShimVariable(kind))
        #expect(locator.shimDirectoryName == "\(kind.rawValue)-shim")
        // The app the tests run in carries every shim.
        let bundled = try #require(locator.shimDirectoryURL)
        #expect(bundled.lastPathComponent == locator.shimDirectoryName)
    }

    @Test("the shim directories lead the PATH in AgentKind's order")
    func shimDirectories_followAgentKind() {
        #expect(AgentShimLocator.shimDirectoryURLs.map(\.lastPathComponent)
            == AgentKind.allCases.map { "\($0.rawValue)-shim" })
        #expect(AgentShimLocator.zdotdirURL?.deletingLastPathComponent().lastPathComponent == "claude-shim")
    }

    /// Each agent's half of the environment is what its own locator gave
    /// before they were one: the shim directory, and the record directories
    /// for every agent but Codex, whose installer exports them.
    @Test("each agent's variables are the ones its locator exported", arguments: AgentKind.allCases, [true, false])
    func environment_isWhatEachLocatorExported(kind: AgentKind, writesRecords: Bool) throws {
        let shim = try #require(AgentShimLocator(kind).shimDirectoryURL)
        var expected = [Self.historicalShimVariable(kind): shim.path]
        let directories = try #require(
            AgentProviderRegistry.directories(under: WeirPaths.applicationSupportDirectory())[kind.rawValue]
        )
        let records = AgentProviderRegistry.environment(
            for: kind.rawValue,
            state: directories.state,
            sessions: directories.sessions,
            cwdEvents: directories.cwdEvents,
            writesRecords: writesRecords
        )
        switch kind {
        case .claude, .antigravity, .opencode:
            expected.merge(records) { _, new in new }
        case .codex:
            break
        }
        #expect(AgentShimLocator(kind).environment(writesRecords: writesRecords) == expected)
    }

    @Test("only Claude's record directories go out without its shim")
    func recordsWithoutShim_areClaudesAlone() {
        for kind in AgentKind.allCases {
            #expect(AgentShimLocator(kind).exportsRecordsWithoutShim == (kind == .claude), "\(kind)")
            #expect(AgentShimLocator(kind).exportsRecordDirectories == (kind != .codex), "\(kind)")
        }
    }

    // MARK: - The pane's zsh

    /// Runs the bundled `zdotdir` as a pane's interactive zsh does, with a
    /// `.zshrc` of the person's that puts its own folder first, and returns
    /// the PATH the shell ends with.
    private static func finalPath(environment: [String: String], in root: URL) throws -> String? {
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("export PATH=\"/opt/person/bin:$PATH\"\n".utf8).write(to: home.appendingPathComponent(".zshrc"))
        let output = root.appendingPathComponent("path-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-i", "-c", "builtin print -r -- \"$PATH\""]
        shell.environment = try [
            "HOME": home.path,
            "ZDOTDIR": AgentCatalogFixture.shimFolder("claude-shim").appendingPathComponent("zdotdir").path
        ].merging(environment) { _, new in new }
        shell.standardOutput = try FileHandle(forWritingTo: output)
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        guard shell.waitUntilExit(within: 10) else {
            Issue.record("zsh did not exit within ten seconds")
            return nil
        }
        return try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The list puts the shims back in the order the four variables did, so
    /// the PATH a pane's shell ends with is the one it ended with before, and
    /// a shell an earlier build started, which has only the four, still
    /// gets them back.
    @Test(.disabled(if: !RepoFixture.hasLocalRepo, "the zdotdir is in the source tree"))
    func theShimList_putsTheShimsBackInTheOrderTheVariablesDid() throws {
        try withTempDir { root in
            var directories: [AgentKind: URL] = [:]
            for kind in AgentKind.allCases {
                let directory = root.appendingPathComponent("\(kind.rawValue)-shim")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                directories[kind] = directory
            }
            let ordered = AgentKind.allCases.compactMap { directories[$0] }
            let paneVariables = PaneShellEnvironment.variables(
                paneID: nil, shimDirectories: ordered, zdotdir: nil, basePath: "/usr/bin:/bin"
            )
            let panePath = try #require(paneVariables["PATH"])
            var perKind = ["PATH": panePath]
            for kind in AgentKind.allCases {
                perKind[Self.historicalShimVariable(kind)] = directories[kind]?.path
            }
            var withList = perKind
            withList[PaneShellEnvironment.shimDirectoriesVariable] = paneVariables[PaneShellEnvironment.shimDirectoriesVariable]

            // A list that is there but empty is no list: the four still count.
            var withEmptyList = perKind
            withEmptyList[PaneShellEnvironment.shimDirectoriesVariable] = ""

            let before = try #require(try Self.finalPath(environment: perKind, in: root))
            let after = try #require(try Self.finalPath(environment: withList, in: root))
            let afterEmpty = try #require(try Self.finalPath(environment: withEmptyList, in: root))
            #expect(after == before)
            #expect(afterEmpty == before)
            let leading = ordered.reversed().map(\.path) + ["/opt/person/bin"]
            #expect(after.split(separator: ":").prefix(leading.count).map(String.init) == leading)
        }
    }
}
