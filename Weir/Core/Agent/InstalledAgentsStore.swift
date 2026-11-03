// InstalledAgentsStore.swift
// Weir — the agents found on this Mac, kept for each project so a menu can read them as it opens.

import Foundation
import Observation
import WeirDomain

/// The agents `AgentCatalog.detectInstallations` last found, for each
/// project and for the panes outside one. The pane strip's "+" opens at
/// once and cannot wait for a lookup, so it reads what is kept here; the
/// new worktree sheet waits for a lookup of its own as it opens anyway,
/// and hands what it found back (`record`), so both name the same agents.
///
/// Each project has its own entry because detection also searches the
/// `PATH` a pane of that project last had, which may hold the project's
/// own folders.
///
/// Lookups end in any order: the sheet's waits on Git as well, and a
/// lookup begun on coming to the front can end before one begun on
/// hovering "+". Each is numbered as it begins (`beginLookup`), and a
/// result older than the one a project already keeps is dropped, so an
/// agent installed or removed meanwhile is not undone by a late answer.
@MainActor
@Observable
final class InstalledAgentsStore {
    /// Finds the agents for a project, `nil` for none; a test gives its own.
    typealias Detect = @Sendable (UUID?) async -> [AgentInstallation]

    /// One lookup for a project, numbered as it began.
    struct Lookup: Sendable {
        let projectID: UUID?
        fileprivate let number: Int
    }

    /// Keyed by the project, `nil` for the panes outside one.
    private var found: [UUID?: [AgentKind]] = [:]
    /// The number of the lookup each entry of `found` came from.
    @ObservationIgnored private var keptLookup: [UUID?: Int] = [:]
    @ObservationIgnored private var lookupsBegun = 0
    @ObservationIgnored private let detect: Detect

    init(detect: @escaping Detect = InstalledAgentsStore.liveDetect) {
        self.detect = detect
    }

    /// The agents last found for `projectID`, in the catalog's order;
    /// `nil` until they were looked for once.
    func installedAgents(for projectID: UUID?) -> [AgentKind]? {
        found[projectID]
    }

    /// The agents found for any project, in the catalog's order, for what
    /// belongs to no project, as the plan usage panel; `nil` until they
    /// were looked for once.
    var installedAnywhere: [AgentKind]? {
        guard !found.isEmpty else { return nil }
        let kinds = Set(found.values.joined())
        return AgentCatalog.entries.map(\.kind).filter(kinds.contains)
    }

    /// Looks the agents up again for `projectID`.
    func refresh(projectID: UUID?) async {
        let lookup = beginLookup(for: projectID)
        let installations = await detect(projectID)
        record(installations, from: lookup)
    }

    /// Numbers a lookup about to begin, for `record(_:from:)`.
    func beginLookup(for projectID: UUID?) -> Lookup {
        lookupsBegun += 1
        return Lookup(projectID: projectID, number: lookupsBegun)
    }

    /// Looks them up again for every project already looked up once: on
    /// coming to the front, since an agent may have been installed or
    /// removed while Weir was behind.
    func refreshKnown() async {
        for projectID in Array(found.keys) {
            await refresh(projectID: projectID)
        }
    }

    /// Keeps what `lookup` found, unless a lookup begun after it was kept
    /// already; the new worktree sheet hands its own lookup's here.
    func record(_ installations: [AgentInstallation], from lookup: Lookup) {
        let projectID = lookup.projectID
        if let kept = keptLookup[projectID], kept > lookup.number {
            return
        }
        keptLookup[projectID] = lookup.number
        let kinds = installations.map(\.kind)
        // Kept as it was when nothing changed, so a lookup on each coming
        // to the front does not redraw every "+".
        if found[projectID] != kinds {
            found[projectID] = kinds
        }
    }

    /// The lookup the sheet makes, with the project's pane `PATH` record.
    /// A demo run neither writes nor reads the person's files, so it reads
    /// no record.
    nonisolated static func liveDetect(_ projectID: UUID?) async -> [AgentInstallation] {
        let record = projectID.flatMap { id in
            DemoFixture.isDemoActive
                ? nil
                : AgentCatalog.panePathRecordURL(in: WeirPaths.applicationSupportDirectory(), project: id)
        }
        return await AgentCatalog.detectInstallations(panePathRecord: record)
    }
}
