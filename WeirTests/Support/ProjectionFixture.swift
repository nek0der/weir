// ProjectionFixture.swift
// Weir — builds a projection adapter over a scratch provider directory.
//
// Suites that need one provider's rules exercised construct this: it wires
// the provider's directories into an adapter with an injectable liveness
// answer.

import Foundation
import Synchronization
@testable import Weir

@MainActor
enum ProjectionFixture {
    /// The leftover sweep a bootstrap queues runs in the background, so a
    /// suite that plants a lone lock sidecar or a temporary would race it.
    /// What the sweep removes is the bridge's own suite's to check.
    static let sweepsNothing: TurnGarbageCollector.Sweep = { _ in
        LeftoverSweep(sidecars: 0, temporaries: 0, counters: 0)
    }

    /// Makes an adapter reading one provider's records out of `state`, its resume
    /// hints out of `sessions`, and its cwd moves out of `cwdEvents`, with
    /// liveness answered by `processStatus`. `writesFiles: false` reads as
    /// demo mode does, writing nothing. `turnCollector`, `turnDeletionsURL`,
    /// `stoppedTurns`, and `engine` default to what the adapter itself
    /// defaults to, so a suite names only the one it observes or makes fail;
    /// the collector's launch sweep alone is left out (`sweepsNothing`).
    static func adapter(
        provider: String = "codex",
        state: URL,
        sessions: URL,
        cwdEvents: URL? = nil,
        resumeIntents: AgentResumeIntentStore? = nil,
        writesFiles: Bool = true,
        forgottenHintsURL: URL? = nil,
        turnDeletionsURL: URL? = nil,
        processStatus: @escaping (String?) -> AgentProcessStatus = AgentProcessStatus.inspect,
        turnCollector: TurnGarbageCollector = TurnGarbageCollector(sweep: sweepsNothing),
        stoppedTurns: StoppedTurnCloser = StoppedTurnCloser(),
        engine: any ProjectionPassing = WeirProjectionBridge.Engine()
    ) -> AgentProjectionAdapter {
        AgentProjectionAdapter(
            directories: [provider: AgentDirectories(state: state, sessions: sessions, cwdEvents: cwdEvents)],
            descriptors: AgentProviderRegistry.descriptors.filter { $0.key == provider },
            resumeIntents: resumeIntents
                ?? AgentResumeIntentStore(
                    directory: state.appendingPathComponent("resume-intents", isDirectory: true),
                    writesFiles: writesFiles
                ),
            writesFiles: writesFiles,
            forgottenHintsURL: forgottenHintsURL,
            turnDeletionsURL: turnDeletionsURL,
            processStatus: processStatus,
            turnCollector: turnCollector,
            stoppedTurns: stoppedTurns,
            engine: engine
        )
    }
}

/// The real engine, with its passes made to fail on demand: what the adapter
/// does with a pass the rules could not answer.
final class FailingEngine: ProjectionPassing {
    private let engine = WeirProjectionBridge.Engine()
    private let isFailing = Mutex(false)

    func fails(_ isFailing: Bool) {
        self.isFailing.withLock { $0 = isFailing }
    }

    func pass(input: Data, now: Data) throws -> WeirProjectionPass {
        if isFailing.withLock({ $0 }) {
            throw WeirProjectionError.rust(-1)
        }
        return try engine.pass(input: input, now: now)
    }

    func commit(_ proposal: UInt64) throws {
        try engine.commit(proposal)
    }

    func turnsTaken(change: Data, now: Data) throws -> Int {
        try engine.turnsTaken(change: change, now: now)
    }
}
