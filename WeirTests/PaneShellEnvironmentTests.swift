// PaneShellEnvironmentTests.swift
// Weir — pins the env every pty inherits regardless of which agent runs
// in it. The behavior lived in what was Claude's shim locator, which resolved
// its paths from `Bundle.main` and so could not be exercised from a test
// bundle at all; taking the values as arguments is what makes these
// assertions possible.

import Foundation
import Testing
@testable import Weir

@Suite("PaneShellEnvironment")
struct PaneShellEnvironmentTests {
    private let base = "/usr/bin:/bin"

    /// With no pane, no shim directory, and no agent tmux, every optional
    /// variable is left out: a bundle without the shim resources (the test
    /// target's own case) leaves the person's PATH untouched rather than
    /// with an empty leading entry, and the shims host in tmux only when
    /// the tmux variables are there, so they are absent, not empty, with
    /// the setting off.
    @Test("the least input sets no optional variable")
    func variables_leastInput_setsNoOptionalVariable() {
        let env = PaneShellEnvironment.variables(
            paneID: nil, shimDirectories: [], zdotdir: nil, basePath: base
        )
        #expect(env.isEmpty)
    }

    @Test("prepends every shim directory to PATH, in order")
    func variables_prependsShimDirectories() {
        let env = PaneShellEnvironment.variables(
            paneID: nil,
            shimDirectories: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")],
            zdotdir: nil,
            basePath: base
        )
        #expect(env == ["PATH": "/a:/b:/usr/bin:/bin", "WEIR_SHIM_DIRS": "/a:/b"])
    }

    @Test("carries the pane id and the startup-file redirect")
    func variables_carriesPaneIDAndZdotdir() {
        let id = UUID()
        let env = PaneShellEnvironment.variables(
            paneID: id,
            shimDirectories: [],
            zdotdir: URL(fileURLWithPath: "/z"),
            basePath: base
        )
        #expect(env == ["WEIR_PANE_ID": id.uuidString, "ZDOTDIR": "/z"])
    }

    /// The shims test one variable to decide whether to host the agent
    /// in tmux, so it has to be absent — not empty — when the setting is
    /// off. The socket name rides along because the server has to be
    /// ours alone: each build counts a client of its own server as its
    /// agent host, and our server-wide options must not land on a server
    /// the person uses.
    @Test("carries the tmux binary and socket when the agent is hosted")
    func variables_carriesAgentTmuxHost() {
        let env = PaneShellEnvironment.variables(
            paneID: nil,
            shimDirectories: [],
            zdotdir: nil,
            basePath: base,
            agentTmux: .init(binary: "/opt/homebrew/bin/tmux", socketName: "weir-x")
        )
        #expect(env == ["WEIR_AGENT_TMUX": "/opt/homebrew/bin/tmux", "WEIR_AGENT_TMUX_SOCKET": "weir-x"])
    }

    /// Namespaced so two builds never share a server; see above.
    @Test("names the socket after the running build")
    func defaultAgentSocketName_isNamespaced() {
        let name = PaneShellEnvironment.defaultAgentSocketName()
        #expect(name == "weir-" + WeirPaths.bundleID)
        #expect(name != "weir-unknown")
    }

    @Test func aPanesEnvironment_namesTheRecord_onlyWhenGivenOne() {
        let record = URL(fileURLWithPath: "/tmp/weir-test/pane-path.txt")
        let with = PaneShellEnvironment.variables(
            paneID: nil,
            shimDirectories: [],
            zdotdir: nil,
            basePath: base,
            panePathRecord: record
        )
        #expect(with == ["WEIR_PANE_PATH_RECORD": "/tmp/weir-test/pane-path.txt"])
        let without = PaneShellEnvironment.variables(paneID: nil, shimDirectories: [], zdotdir: nil, basePath: base)
        #expect(without["WEIR_PANE_PATH_RECORD"] == nil)
    }

    /// A pane's `PATH` can hold its own folders (`$PWD/bin`), so each
    /// project's panes write their own record, the one the sheet reads for
    /// that project alone; a scratch pane, in no project, writes none.
    /// Otherwise one project's `bin/claude` could be started in another.
    @Test func pathRecordResolution_isProjectSpecific_andOmitsScratchAndNonwritingPanes() {
        let first = UUID()
        let second = UUID()
        let record = { (project: UUID?) in
            PaneShellEnvironment.resolved(forPaneID: nil, recordsPanePath: true, projectID: project)[
                AgentCatalog.panePathRecordVariable
            ]
        }
        let directory = WeirPaths.applicationSupportDirectory()
        #expect(record(first) == AgentCatalog.panePathRecordURL(in: directory, project: first).path)
        #expect(record(second) == AgentCatalog.panePathRecordURL(in: directory, project: second).path)
        #expect(record(first) != record(second))
        #expect(record(nil) == nil)
        #expect(PaneShellEnvironment.resolved(forPaneID: nil, recordsPanePath: false, projectID: first)[
            AgentCatalog.panePathRecordVariable
        ] == nil)
    }
}
