// TmuxPanePresenceTests.swift
// Weir — covers the part of the tmux presence poll that does not need a
// live surface: which panes a tmux session reaches, directly or through a
// nested client, which pane a client on a tty belongs to, which clients are
// Weir's agent server, how a pane's job in front is judged from them, and
// when a probe's result is kept and reported. The join itself (libghostty's
// foreground pid for a mounted pane) cannot be exercised from a test bundle,
// so the surfaces and the tmux are stand-ins.

import Darwin
import Foundation
import Synchronization
import Testing
@testable import Weir

@Suite("TmuxPanePresence")
struct TmuxPanePresenceTests {
    @Test("one tmux session projects to every attached Weir pane")
    func paneIDs_multipleClients_returnsEveryPresentation() {
        let first = UUID()
        let second = UUID()
        let other = UUID()
        let bindings = [
            first: TmuxBinding(socketPath: "/tmp/s", sessionID: "$1", sessionName: "work"),
            second: TmuxBinding(socketPath: "/tmp/s", sessionID: "$1", sessionName: "work"),
            other: TmuxBinding(socketPath: "/tmp/s", sessionID: "$2", sessionName: "other")
        ]

        #expect(TmuxPanePresence.paneIDs(
            in: bindings,
            socketPath: "/tmp/s",
            sessionID: "$1",
            aliases: ["/tmp/s": "/private/tmp/s"]
        ) == [first, second])
    }

    /// A resume's deadline takes a tmux client in front for the agent only
    /// on Weir's own agent server, named per build in tmux's directory;
    /// a session of the person's default server, or of a socket another
    /// build uses, is not ours. `/tmp` and `/private/tmp` are one place.
    @Test("a tmux client is the agent's host only on Weir's agent server")
    func isAgentHost_onlyOnTheAgentSocket() {
        let directory = URL(fileURLWithPath: "/tmp/tmux-501", isDirectory: true)
        let agentSocket = TmuxPanePresence.agentSocketPath(serverDirectory: directory, socketName: "weir-com.nekoder.weir.app")
        #expect(agentSocket == "/tmp/tmux-501/weir-com.nekoder.weir.app")
        let ours = TmuxBinding(
            socketPath: "/private/tmp/tmux-501/weir-com.nekoder.weir.app",
            sessionID: "$1",
            sessionName: "weir-1a2b3c4d-42"
        )
        let theirs = TmuxBinding(socketPath: "/tmp/tmux-501/default", sessionID: "$0", sessionName: "0")
        let otherBuild = TmuxBinding(
            socketPath: "/tmp/tmux-501/weir-com.nekoder.weir.app.dev",
            sessionID: "$1",
            sessionName: "weir-1a2b3c4d-7"
        )
        #expect(TmuxPanePresence.isAgentHost(ours, agentSocketPath: agentSocket))
        #expect(!TmuxPanePresence.isAgentHost(theirs, agentSocketPath: agentSocket))
        #expect(!TmuxPanePresence.isAgentHost(otherBuild, agentSocketPath: agentSocket))
    }

    /// No probe has matched the pane's client yet: not Weir's host.
    @MainActor
    @Test("a pane with no matched client hosts no agent")
    func isAgentHost_withoutAMatchedClient_isFalse() {
        let paneID = UUID()
        let presence = TmuxPanePresence(bindingsByPaneID: [
            paneID: TmuxBinding(socketPath: TmuxPanePresence.agentSocketPath(), sessionID: "$1", sessionName: "weir")
        ])
        // The binding stands, but no surface showed a tmux client in front.
        #expect(!presence.isAgentHost(inPane: paneID))
        #expect(!presence.isAgentHost(inPane: UUID()))
    }

    /// Two surfaces on one tty cannot be told apart, so the client goes to
    /// neither.
    @MainActor
    @Test func ambiguousTTY_isNotAssignedToEitherSurface() {
        let frames = [UUID(), UUID()].map {
            TmuxSurfaceSnapshot(paneID: $0, tty: "/dev/tty1", foregroundPID: 10, foregroundName: "tmux")
        }
        let binding = TmuxBinding(
            socketPath: "/tmp/s", sessionID: "$1", sessionName: "work", serverPID: "42", serverStartedAt: "100", isProvisional: false
        )
        let clients = ["/dev/tty1": binding]
        #expect(TmuxPanePresence.resolveClients(frames: Array(frames.prefix(1)), clients: clients) == [frames[0].paneID: binding])
        #expect(TmuxPanePresence.resolveClients(frames: frames, clients: clients).isEmpty)
    }

    /// Two servers, the person's outer one and an inner one started from a
    /// pane of it. The inner client writes to that pane's pty.
    private static let outerSocket = "/private/tmp/tmux-501/default"
    private static let innerSocket = "/private/tmp/tmux-501/inner"
    private static func nestedTopology(outerPaneActive: Bool = true) -> TmuxTopology {
        let outerPanes = TmuxTopology.parsePanes(
            "42\t100\t$1\t@1\t%1\t1\t\(outerPaneActive ? 1 : 0)\t0\t/dev/ttys020\n",
            socketPath: outerSocket
        )
        let innerPanes = TmuxTopology.parsePanes("43\t200\t$7\t@9\t%3\t1\t1\t0\t/dev/ttys021\n", socketPath: innerSocket)
        return TmuxTopology(
            clients: [
                "/dev/ttys010": TmuxBinding(socketPath: outerSocket, sessionID: "$1", sessionName: "outer"),
                "/dev/ttys020": TmuxBinding(socketPath: innerSocket, sessionID: "$7", sessionName: "inner")
            ],
            panes: outerPanes + innerPanes,
            socketAliases: [outerSocket: outerSocket, innerSocket: innerSocket],
            outcomes: [outerSocket: .success(""), innerSocket: .success("")]
        )
    }

    /// An agent run in the inner server is in front of the Weir pane whose
    /// outer client shows the pane the inner client runs in, and is focused
    /// there only while that outer pane is.
    @MainActor
    @Test(arguments: [true, false])
    func nestedClient_attachesTheInnerRunToTheOuterWeirPane(outerPaneActive: Bool) throws {
        let paneID = UUID()
        let topology = Self.nestedTopology(outerPaneActive: outerPaneActive)
        let presence = TmuxPanePresence(
            bindingsByPaneID: TmuxPanePresence.resolveClients(
                frames: [TmuxSurfaceSnapshot(paneID: paneID, tty: "/dev/ttys010", foregroundPID: 10, foregroundName: "tmux")],
                clients: topology.clients
            ),
            topology: topology,
            surfaces: { [TmuxSurfaceSnapshot(paneID: paneID, tty: "/dev/ttys010", foregroundPID: 10, foregroundName: "tmux")] }
        )
        presence.refreshLocalSurfaces()
        let inner = TmuxRuntimeEndpoint(socketPath: Self.innerSocket, serverPID: "43", serverStartedAt: "200", paneID: "%3")

        let location = try #require(presence.attachments(for: inner)[paneID])
        #expect(location.paneID == "%3")
        #expect(location.isActive == outerPaneActive)
        #expect(location.isVisible == true)
        #expect(presence.resolution(for: inner) == .attached)
        // Selecting it selects the outer pane the inner client runs in first.
        #expect(location.route.map(\.paneID) == ["%1"])
        #expect(location.route.first?.socketPath == Self.outerSocket)
        // The pane still reattaches to the outer session, not the inner.
        #expect(presence.client(inPane: paneID)?.sessionID == "$1")
    }

    /// With no outer pane's pty known (an older tmux, or the inner client on
    /// a tty of nothing we show), the inner run stays attached to no pane.
    @Test func nestedReach_withoutThePanesTTY_reachesNothing() {
        var topology = Self.nestedTopology()
        for index in topology.panes.indices {
            topology.panes[index].paneTTY = nil
        }
        let paneID = UUID()
        let bindings = [paneID: TmuxBinding(socketPath: Self.outerSocket, sessionID: "$1", sessionName: "outer")]
        #expect(TmuxPanePresence.nestedReach(from: bindings, topology: topology).isEmpty)
        #expect(TmuxPanePresence.nestedReach(from: bindings, topology: Self.nestedTopology())[paneID]?.map(\.sessionID) == ["$7"])
    }

    /// Inner session B is shown through two outer panes, a hidden one
    /// listed first and the active one; B runs a client of C. C is in front
    /// through the active way, which is the route kept.
    @Test func nestedReach_twoWaysIn_keepsTheOneInFront_allTheWayIn() throws {
        let deep = "/private/tmp/tmux-501/deep"
        let outerPanes = TmuxTopology.parsePanes(
            """
            42\t100\t$1\t@1\t%1\t0\t1\t0\t/dev/ttys020
            42\t100\t$1\t@2\t%2\t1\t1\t0\t/dev/ttys022
            """,
            socketPath: Self.outerSocket
        )
        let innerPanes = TmuxTopology.parsePanes("43\t200\t$7\t@9\t%3\t1\t1\t0\t/dev/ttys021\n", socketPath: Self.innerSocket)
        let deepPanes = TmuxTopology.parsePanes("44\t300\t$4\t@4\t%5\t1\t1\t0\t/dev/ttys030\n", socketPath: deep)
        let inner = TmuxBinding(socketPath: Self.innerSocket, sessionID: "$7", sessionName: "inner")
        let topology = TmuxTopology(
            clients: [
                "/dev/ttys020": inner,
                "/dev/ttys022": inner,
                "/dev/ttys021": TmuxBinding(socketPath: deep, sessionID: "$4", sessionName: "deep")
            ],
            panes: outerPanes + innerPanes + deepPanes,
            socketAliases: [Self.outerSocket: Self.outerSocket, Self.innerSocket: Self.innerSocket, deep: deep]
        )
        let paneID = UUID()
        let reach = try #require(TmuxPanePresence.nestedReach(
            from: [paneID: TmuxBinding(socketPath: Self.outerSocket, sessionID: "$1", sessionName: "outer")],
            topology: topology
        )[paneID])

        let deepReach = try #require(reach.first { $0.sessionID == "$4" })
        #expect(deepReach.isActive)
        #expect(deepReach.isVisible == true)
        #expect(deepReach.route.map(\.paneID) == ["%2", "%3"])
        #expect(reach.first { $0.sessionID == "$7" }?.route.map(\.paneID) == ["%2"])
    }

    /// The pane's foreground pid changes every time it is read, as it does
    /// while a build runs in some pane: the probe's result is still joined
    /// and kept, and not thrown away for another probe.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func probe_whileOnlyAForegroundPIDChanges_keepsItsResult() async {
        let paneID = UUID()
        let binding = TmuxBinding(
            socketPath: Self.outerSocket, sessionID: "$1", sessionName: "outer",
            serverPID: "42", serverStartedAt: "100", isProvisional: false
        )
        let probes = ProbeScript([Self.batch(clients: ["/dev/ttys010": binding])])
        var pid: Int32 = 100
        let presence = TmuxPanePresence(runner: probes.runner)
        presence.start(surfaces: {
            pid += 1
            return [TmuxSurfaceSnapshot(paneID: paneID, tty: "/dev/ttys010", foregroundPID: pid, foregroundName: "tmux")]
        }, candidates: { [] })
        defer { presence.stop() }

        await pollUntil(timeout: .seconds(10), interval: .milliseconds(10)) { presence.bindingsByPaneID[paneID] != nil }
        #expect(presence.bindingsByPaneID[paneID] == binding)
        #expect(probes.count == 1)
    }

    /// A pane opens while the first probe runs, so its clients are not
    /// joined and a second probe follows at once; what the first heard from
    /// its server is kept all the same, or a server it alone visited would
    /// go unobserved for another round and its sessions expire.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func probe_whileAPaneOpens_keepsWhatItsServersSaid() async {
        let paneID = UUID()
        let other = "/private/tmp/tmux-501/other"
        let binding = TmuxBinding(
            socketPath: Self.outerSocket, sessionID: "$1", sessionName: "outer",
            serverPID: "42", serverStartedAt: "100", isProvisional: false
        )
        var first = Self.batch(clients: [:])
        first.snapshot.socketAliases[other] = other
        first.snapshot.outcomes = [other: .success("")]
        // Stamped now: the second pass's merge expires an older one.
        first.snapshot.observedAt = [other: ProcessInfo.processInfo.systemUptime]
        first.snapshot.panes = []
        var second = Self.batch(clients: ["/dev/ttys010": binding])
        second.snapshot.socketAliases[other] = other
        let openedPane = UUID()
        let opened = Mutex(false)
        let probes = ProbeScript([first, second]) { opened.withLock { $0 = true } }
        let presence = TmuxPanePresence(runner: probes.runner)
        presence.start(surfaces: {
            let tmux = TmuxSurfaceSnapshot(paneID: paneID, tty: "/dev/ttys010", foregroundPID: 10, foregroundName: "tmux")
            return opened.withLock { $0 }
                ? [tmux, TmuxSurfaceSnapshot(paneID: openedPane, tty: "/dev/ttys011", foregroundPID: 11, foregroundName: "zsh")]
                : [tmux]
        }, candidates: { [] })
        defer { presence.stop() }

        await pollUntil(timeout: .seconds(10), interval: .milliseconds(10)) { presence.bindingsByPaneID[paneID] != nil }
        #expect(presence.bindingsByPaneID[paneID] == binding)
        #expect(probes.count == 2)
        #expect(presence.topology.outcomes[other] == .success(""))
    }

    /// A probe that sees what the last one saw, stamped later, asks for no
    /// projection pass; the next one that sees something new does.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func probe_thatSeesNothingNew_reportsNoChange() async throws {
        let paneID = UUID()
        let outer = TmuxBinding(
            socketPath: Self.outerSocket, sessionID: "$1", sessionName: "outer",
            serverPID: "42", serverStartedAt: "100", isProvisional: false
        )
        let renamed = TmuxBinding(
            socketPath: Self.outerSocket, sessionID: "$1", sessionName: "renamed",
            serverPID: "42", serverStartedAt: "100", isProvisional: false
        )
        let probes = ProbeScript([
            Self.batch(clients: ["/dev/ttys010": outer], stamp: 1),
            Self.batch(clients: ["/dev/ttys010": outer], stamp: 2),
            Self.batch(clients: ["/dev/ttys010": renamed], stamp: 3)
        ])
        let presence = TmuxPanePresence(runner: probes.runner)
        var reportedAtProbe: [Int] = []
        presence.onBindingsChanged = { reportedAtProbe.append(probes.count) }
        presence.start(
            surfaces: { [TmuxSurfaceSnapshot(paneID: paneID, tty: "/dev/ttys010", foregroundPID: 10, foregroundName: "tmux")] },
            candidates: { [] }
        )
        defer { presence.stop() }

        await pollUntil(timeout: .seconds(10), interval: .milliseconds(10)) { !reportedAtProbe.isEmpty }
        try #require(reportedAtProbe.first == 1)

        presence.refresh()
        await pollUntil(timeout: .seconds(10), interval: .milliseconds(10)) {
            (presence.topology.observedAt[Self.outerSocket] ?? 0) >= 2
        }
        try #require((presence.topology.observedAt[Self.outerSocket] ?? 0) >= 2)

        presence.refresh()
        await pollUntil(timeout: .seconds(10), interval: .milliseconds(10)) {
            presence.bindingsByPaneID[paneID] == renamed
        }
        #expect(reportedAtProbe == [1, 3])
        #expect(presence.bindingsByPaneID[paneID] == renamed)
    }

    /// A pane that left tmux is remembered as detached for the quit's
    /// capture until the pane itself is closed.
    @MainActor
    @Test func detachedPane_isForgottenOnceClosed() {
        let paneID = UUID()
        var frames = [TmuxSurfaceSnapshot(paneID: paneID, tty: "/dev/ttys010", foregroundPID: 10, foregroundName: "tmux")]
        let presence = TmuxPanePresence(surfaces: { frames })
        presence.refreshLocalSurfaces()
        frames = [TmuxSurfaceSnapshot(paneID: paneID, tty: "/dev/ttys010", foregroundPID: 11, foregroundName: "zsh")]
        presence.refreshLocalSurfaces()
        #expect(presence.detachedPaneIDs == [paneID])
        frames = []
        presence.refreshLocalSurfaces()
        #expect(presence.detachedPaneIDs.isEmpty)
    }

    private static func batch(clients: [String: TmuxBinding], stamp: TimeInterval = 1) -> TmuxClientProbe.ProbeBatch {
        TmuxClientProbe.ProbeBatch(
            snapshot: TmuxTopology(
                clients: clients,
                panes: TmuxTopology.parsePanes("42\t100\t$1\t@1\t%1\t1\t1\t0\t/dev/ttys020\n", socketPath: outerSocket),
                socketAliases: [outerSocket: outerSocket],
                outcomes: [outerSocket: .success("")],
                observedAt: [outerSocket: stamp]
            ),
            nextCursor: 0
        )
    }
}

/// The machine's tmux, stood in for by the batches each probe returns in
/// turn, the last again once they run out. Counts the probes.
private final class ProbeScript: Sendable {
    private let state: Mutex<(batches: [TmuxClientProbe.ProbeBatch], count: Int)>
    /// Run during the first probe, as something the person did meanwhile.
    private let duringFirst: @Sendable () -> Void

    init(_ batches: [TmuxClientProbe.ProbeBatch], duringFirst: @escaping @Sendable () -> Void = {}) {
        state = Mutex((batches, 0))
        self.duringFirst = duringFirst
    }

    var count: Int {
        state.withLock { $0.count }
    }

    var runner: TmuxProbeRunner {
        TmuxProbeRunner(locate: { "/usr/bin/false" }, probe: { [self] _, _, _, _ in
            let batch = state.withLock { state in
                let batch = state.batches[min(state.count, state.batches.count - 1)]
                state.count += 1
                return (batch, state.count)
            }
            if batch.1 == 1 {
                duringFirst()
            }
            return batch.0
        })
    }
}

/// What the pane's job in front stands for behind a tmux client, judged
/// from the attachment the presence holds (`TmuxPaneJob.inFront(of:inPane:
/// presence:)`), the one judgement a resume's deadline and a pane's badge
/// share. The presence is told which panes show a tmux client through its
/// surfaces, and the person's tmux is a recording stand-in, so no tmux runs.
@MainActor
@Suite("TmuxPaneJob attachment")
struct TmuxPaneJobAttachmentTests {
    private let paneID = UUID()
    private let persons = TmuxBinding(socketPath: "/tmp/tmux-501/default", sessionID: "$3", sessionName: "work")
    private var hosted: TmuxBinding {
        TmuxBinding(socketPath: TmuxPanePresence.agentSocketPath(), sessionID: "$1", sessionName: "weir-1a2b3c4d-42")
    }

    /// A presence whose surface for `paneID` shows `foreground` in front,
    /// with `binding` the client the last probe matched to it.
    private func makePresence(binding: TmuxBinding?, foreground: @escaping () -> String) -> TmuxPanePresence {
        let paneID = paneID
        let presence = TmuxPanePresence(
            bindingsByPaneID: binding.map { [paneID: $0] } ?? [:],
            surfaces: { [TmuxSurfaceSnapshot(paneID: paneID, tty: "/dev/ttys010", foregroundPID: 10, foregroundName: foreground())] }
        )
        presence.refreshLocalSurfaces()
        return presence
    }

    private final class PersonsTmux {
        var asked: [TmuxBinding] = []
        func read(_ binding: TmuxBinding) -> TmuxPaneJob {
            asked.append(binding)
            return .pane(["zsh"])
        }
    }

    @Test func aClientOfWeirsAgentServer_isTheAgentsHost_withNoServerAsked() async {
        let tmux = PersonsTmux()
        let presence = makePresence(binding: hosted) { "tmux" }
        let job = await TmuxPaneJob.inFront(of: ["tmux"], inPane: paneID, presence: presence, read: tmux.read)
        #expect(job == .agentHost)
        #expect(tmux.asked.isEmpty)
    }

    @Test func aClientOfThePersonsTmux_isAskedForItsActivePane() async {
        let tmux = PersonsTmux()
        let presence = makePresence(binding: persons) { "tmux" }
        let job = await TmuxPaneJob.inFront(of: ["tmux"], inPane: paneID, presence: presence, read: tmux.read)
        #expect(job == .pane(["zsh"]))
        #expect(tmux.asked == [persons])
    }

    /// No tmux client in front: nothing to ask, even with an attachment
    /// on record for the pane.
    @Test func noTmuxClientInFront_asksNothing() async {
        let tmux = PersonsTmux()
        let presence = makePresence(binding: hosted) { "tmux" }
        let job = await TmuxPaneJob.inFront(of: ["zsh"], inPane: paneID, presence: presence, read: tmux.read)
        #expect(job == .unknown)
        #expect(tmux.asked.isEmpty)
    }

    /// The client left the pane since the probe matched it: the job read a
    /// moment before still names tmux, but the attachment the presence held
    /// is gone with the client, so it is neither Weir's host nor the
    /// person's tmux to ask.
    @Test(arguments: [false, true])
    func anAttachmentTheClientLeft_isNeitherHostNorAsked(isHosted: Bool) async {
        let tmux = PersonsTmux()
        var foreground = "tmux"
        let presence = makePresence(binding: isHosted ? hosted : persons) { foreground }
        foreground = "zsh"
        presence.refreshLocalSurfaces()

        // Dropped, not only hidden: the projection reads the bindings
        // themselves for which panes show a session.
        #expect(presence.bindingsByPaneID[paneID] == nil)
        #expect(presence.client(inPane: paneID) == nil)
        let job = await TmuxPaneJob.inFront(of: ["tmux"], inPane: paneID, presence: presence, read: tmux.read)
        #expect(job == .unknown)
        #expect(tmux.asked.isEmpty)
    }

    /// A binding no surface backs, as one restored from disk before the
    /// pane's first observation: not an attachment to judge by.
    @Test func aBindingNoSurfaceShows_isNotAnAttachment() async {
        let tmux = PersonsTmux()
        let presence = TmuxPanePresence(bindingsByPaneID: [paneID: hosted])
        let job = await TmuxPaneJob.inFront(of: ["tmux"], inPane: paneID, presence: presence, read: tmux.read)
        #expect(job == .unknown)
        #expect(tmux.asked.isEmpty)
    }
}
