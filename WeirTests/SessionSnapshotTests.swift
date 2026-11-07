// SessionSnapshotTests.swift
// Weir — the session snapshot's round-trip, its forward-compatible decoding, and what a restore resets.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("SessionSnapshot", .tags(.persistence))
@MainActor
struct SessionSnapshotTests {

    @Test("round-trip keeps scratch and project tabs, with the projects as containers")
    func roundTrip_keepsScratchAndProjectTabs() throws {
        let s = WorkspaceSession()
        let project = s.addOrActivateProject(rootURL: URL(fileURLWithPath: "/tmp/round-trip-test"))
        let scratchTab = s.openTab(container: .loose)
        let projectTab = s.openTab(container: .project(project.id))

        let snapshot = s.makeSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let containers = try #require(object["containers"] as? [[String: Any]])
        let restored = WorkspaceSession()
        restored.restore(from: decoded)

        #expect(decoded.version == SessionSnapshot.currentVersion)
        #expect(decoded.windows == snapshot.windows)
        // The projects keep the shape the shell worktree hook reads.
        try #require(containers.count == 1)
        let body = try #require(containers[0]["project"] as? [String: Any])
        #expect(containers[0]["kind"] as? String == "project")
        #expect(body["id"] as? String == project.id.uuidString)
        #expect(body["rootURL"] as? String == project.rootURL.absoluteString)
        #expect(restored.projects.map(\.id) == [project.id])
        #expect(restored.projects.map(\.rootURL) == [project.rootURL])
        #expect(restored.tabs.map(\.id) == [scratchTab.id, projectTab.id])
        #expect(restored.tabs.map(\.container) == [.loose, .project(project.id)])
    }

    /// Version 6 never writes a group, but a container of a kind this build
    /// does not know, a group's or a newer build's, costs only itself: the
    /// file still loads, with that container passed over and its tabs
    /// among the scratch tabs.
    @Test("a container of an unknown kind is passed over, and its tabs become scratch tabs")
    func decode_unknownContainerKind_skipsIt_andItsTabsGoToScratch() throws {
        let s = WorkspaceSession()
        let project = s.addOrActivateProject(rootURL: URL(fileURLWithPath: "/tmp/unknown-kind-test"))
        let projectTab = s.openTab(container: .project(project.id))
        let groupTab = s.openTab(container: .loose)
        let futureTab = s.openTab(container: .loose)
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(s.makeSnapshot())) as? [String: Any]
        )
        let groupID = UUID().uuidString
        let futureID = UUID().uuidString
        var containers = try #require(json["containers"] as? [[String: Any]])
        try #require(containers.count == 1)
        let originalContainer = containers[0] as NSDictionary
        containers.insert(["kind": "group", "group": ["id": groupID, "name": "Servers", "isExpanded": true]], at: 0)
        containers.append(["kind": "workspace", "workspace": ["id": futureID]])
        json["containers"] = containers
        var tabs = try #require(json["tabs"] as? [String: Any])
        for (tab, container) in [
            (groupTab, ["group": ["_0": groupID]]),
            (futureTab, ["workspace": ["id": futureID]])
        ] {
            var object = try #require(tabs[tab.id.uuidString] as? [String: Any])
            object["container"] = container
            tabs[tab.id.uuidString] = object
        }
        json["tabs"] = tabs

        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        let restored = WorkspaceSession()
        restored.restore(from: decoded)

        #expect(decoded.version == SessionSnapshot.currentVersion)
        #expect(decoded.projects.map(\.id) == [project.id])
        #expect(restored.tabs.map(\.id) == [projectTab.id, groupTab.id, futureTab.id])
        #expect(restored.tabs.first { $0.id == projectTab.id }?.container == .project(project.id))
        #expect(restored.looseTabs.map(\.id) == [groupTab.id, futureTab.id])
        // Written back, only the project is a container.
        let rewritten = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.makeSnapshot())) as? [String: Any]
        )
        let retained = try #require(rewritten["containers"] as? [NSDictionary])
        #expect(retained == [originalContainer])
        let writtenTabs = try #require(rewritten["tabs"] as? [String: [String: Any]])
        for tab in [groupTab, futureTab] {
            let body = try #require(writtenTabs[tab.id.uuidString])
            #expect(body["container"] as? [String: [String: String]] == ["loose": [:]])
        }
    }

    @Test("a tab whose body repeats an earlier tab's ID is dropped and reported")
    func restore_duplicateTabID_dropsTheLaterTab() throws {
        // The decode keys each tab by its key in `tabs`, so two keys can
        // carry one ID in their bodies. Kept, every lookup by ID finds the
        // first, and Close All Tabs builds a dictionary by tab ID that traps.
        let session = WorkspaceSession()
        let first = session.openTab(container: .loose)
        let second = session.openTab(container: .loose)
        let data = try JSONEncoder().encode(session.makeSnapshot())
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var tabs = try #require(json["tabs"] as? [String: Any])
        let secondKey = try #require(tabs.keys.first { $0.caseInsensitiveCompare(second.id.uuidString) == .orderedSame })
        var body = try #require(tabs[secondKey] as? [String: Any])
        body["id"] = first.id.uuidString
        tabs[secondKey] = body
        json["tabs"] = tabs
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.tabs.map(\.id) == [first.id, first.id])

        let restored = WorkspaceSession()
        let issue = restored.restore(from: decoded)

        #expect(issue == .recovered(droppedTabCount: 1, didResetActiveContainer: false))
        #expect(restored.tabs.map(\.id) == [first.id])
        #expect(restored.tabs.first?.splitTree.allLeafIDs() == first.splitTree.allLeafIDs())
        TabActions.closeAllTabs(restored, registry: NoopSurfaceRegistry(), in: .loose)
        #expect(restored.tabs(in: .loose).isEmpty)
    }

    @Test("an active container that no longer exists is reported as a repair")
    func restore_missingActiveContainer_reportsRecovery() {
        let s = WorkspaceSession()
        let scratch = s.openTab(container: .loose)
        var snap = s.makeSnapshot()
        snap.windows[0].activeTabID = nil
        snap.windows[0].activeContainerID = .project(UUID())

        let restored = WorkspaceSession()
        let issue = restored.restore(from: snap)

        #expect(issue == .recovered(droppedTabCount: 0, didResetActiveContainer: true))
        #expect(restored.primarySelection.activeContainerID == .loose)
        #expect(restored.primarySelection.activeTabID == scratch.id)
    }

    @Test("transient pane state resets on restore; unread persists")
    func restore_resetsTransientPaneStateButKeepsUnread() throws {
        let s = WorkspaceSession()
        let tab = s.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        s.setBell(paneID: paneID, ringing: true)
        s.setChildExited(paneID: paneID, code: 137)
        s.setWorkingDirectory(paneID: paneID, path: "/tmp/transient")
        s.markUnread(paneID: paneID)

        let data = try JSONEncoder().encode(s.makeSnapshot())
        let restored = WorkspaceSession()
        restored.setBell(paneID: paneID, ringing: true)
        restored.setChildExited(paneID: paneID, code: 42)
        restored.setWorkingDirectory(paneID: paneID, path: "/tmp/old-receiver-state")
        #expect(restored.isBellRinging(paneID: paneID))
        #expect(restored.childExitCode(paneID: paneID) == 42)
        #expect(restored.workingDirectory(paneID: paneID) == "/tmp/old-receiver-state")

        try restored.restore(from: JSONDecoder().decode(SessionSnapshot.self, from: data))

        #expect(restored.isBellRinging(paneID: paneID) == false)
        #expect(restored.childExitCode(paneID: paneID) == nil)
        #expect(restored.workingDirectory(paneID: paneID) == nil)
        #expect(restored.paneState(paneID).unreadCount == 1)
    }

    // MARK: - ContainerID forward-compat decoder

    @Test("each ContainerID case matches its persisted JSON")
    func containerID_roundTrip_preservesEachCase() throws {
        let project = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let worktree = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let cases: [(ContainerID, String)] = [
            (.loose, #"{"loose":{}}"#),
            (.project(project), #"{"project":{"_0":"11111111-1111-1111-1111-111111111111"}}"#),
            (
                .worktree(projectID: project, worktreeID: worktree),
                #"{"worktree":{"projectID":"11111111-1111-1111-1111-111111111111","worktreeID":"22222222-2222-2222-2222-222222222222"}}"#
            )
        ]
        for (value, json) in cases {
            let fixture = Data(json.utf8)
            #expect(try JSONDecoder().decode(ContainerID.self, from: fixture) == value)
            let wire = try #require(JSONSerialization.jsonObject(with: fixture) as? NSDictionary)
            let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary)
            #expect(encoded == wire)
        }
    }

    /// A container this build cannot read keeps its tab, among the scratch
    /// tabs, rather than costing the whole snapshot: a newer build's kind,
    /// a group's (written before groups became scratch tabs), or a
    /// known kind whose value is wrong-shaped.
    @Test("a ContainerID this build cannot read decodes as .loose", arguments: [
        #"{"workspace":{"id":"11111111-1111-1111-1111-111111111111"}}"#,
        #"{"group":{"_0":"11111111-1111-1111-1111-111111111111"}}"#,
        #"{"project":{"_0":"not-a-uuid"}}"#
    ])
    func containerID_unreadable_fallsBackToLoose(json: String) throws {
        let restored = try JSONDecoder().decode(ContainerID.self, from: Data(json.utf8))
        #expect(restored == .loose)
        #expect(restored == ContainerID.unknownFallback)
    }

    // MARK: - Forward-compat decoders

    /// A tab whose kind is missing, or one a newer build wrote, opens as
    /// a terminal.
    @Test("a Tab without a kind this build knows decodes as .terminal", arguments: [nil, "future-editor-variant"])
    func tab_unknownOrMissingKind_decodesAsTerminal(kind: String?) throws {
        let session = WorkspaceSession()
        let tab = session.openTab(container: .loose)

        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any]
        )
        json["kind"] = kind
        let decoded = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.kind == .terminal)
    }

    /// A worktree's admission is saved with the session and read back.
    @Test("a worktree's admission survives a save and a restore", arguments: [
        (WorktreeAdmission.created, "created"), (.opened, "opened"), (.discovered, "discovered")
    ])
    func worktreeAdmission_survivesASaveAndARestore(admission: WorktreeAdmission, wireValue: String) throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let row = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: admission)

        let data = try JSONEncoder().encode(session.makeSnapshot())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let containers = try #require(json["containers"] as? [[String: Any]])
        try #require(containers.count == 1)
        let projectBody = try #require(containers[0]["project"] as? [String: Any])
        let worktrees = try #require(projectBody["worktrees"] as? [[String: Any]])
        try #require(worktrees.count == 1)
        #expect(worktrees[0]["id"] as? String == row.id.uuidString)
        #expect(worktrees[0]["admission"] as? String == wireValue)

        let restored = WorkspaceSession()
        try restored.restore(from: JSONDecoder().decode(SessionSnapshot.self, from: data))

        #expect(restored.worktree(projectID: project.id, worktreeID: row.id)?.admission == admission)
    }

    /// A worktree with no admission (every file from before admissions were
    /// kept, or one whose value this build does not know) reads as not yet
    /// admitted, the rest of the row and the file intact; one not yet
    /// admitted is written without the key.
    /// `admissionJSON` is the key's value as JSON text; `nil` leaves the key out.
    @Test("a worktree with no admission, an unknown one, or one of another type reads as not yet admitted", arguments: [
        nil, "\"archived\"", "3", "null"
    ])
    func worktree_unreadableAdmission_readsAsNone(admissionJSON: String?) throws {
        let row = WorktreeFixture.make(label: "feat", isHidden: true, admission: .created)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        json["admission"] = try admissionJSON.map {
            try JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed)
        }

        let decoded = try JSONDecoder().decode(Worktree.self, from: JSONSerialization.data(withJSONObject: json))
        let written = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])

        #expect(decoded.admission == nil)
        #expect(decoded.id == row.id)
        #expect(decoded.label == "feat")
        #expect(decoded.isHidden)
        #expect(written["admission"] == nil)
    }

    /// Only `admission` is lenient: a worktree missing a key it always had
    /// still fails, as it did with the synthesized decoder.
    @Test("a worktree missing isHidden still fails to decode")
    func worktree_missingIsHidden_stillFails() throws {
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(WorktreeFixture.make())) as? [String: Any]
        )
        json["isHidden"] = nil
        let data = try JSONSerialization.data(withJSONObject: json)
        let error = #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Worktree.self, from: data)
        }
        guard case let .keyNotFound(key, _)? = error else {
            Issue.record("Expected the missing isHidden key")
            return
        }
        #expect(key.stringValue == "isHidden")
    }

    @Test("Snapshot wire format encodes tabs as a dictionary keyed by id + a tabOrder array")
    func snapshot_tabsWireShape_isDictPlusOrder() throws {
        let session = WorkspaceSession()
        let first = session.openTab(container: .loose)
        let second = session.openTab(container: .loose)

        let data = try JSONEncoder().encode(session.makeSnapshot())
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        let tabsByID = try #require(json["tabs"] as? [String: [String: Any]])
        let expected = [first.id, second.id]
        #expect(tabsByID.count == expected.count)
        #expect(Set(tabsByID.keys.compactMap(UUID.init(uuidString:))) == Set(expected))
        for (key, tab) in tabsByID {
            let id = try #require(tab["id"] as? String)
            #expect(UUID(uuidString: id) == UUID(uuidString: key))
        }

        let order = try #require(json["tabOrder"] as? [String])
        #expect(order.map { UUID(uuidString: $0) } == expected.map(Optional.some))
    }

    @Test("Snapshot respects declared order and preserves a tab omitted from tabOrder")
    func snapshot_tabOrderWithMissingIds_dropsThem() throws {
        let session = WorkspaceSession()
        let first = session.openTab(container: .loose)
        let second = session.openTab(container: .loose)
        let unlisted = session.openTab(container: .loose)

        let data = try JSONEncoder().encode(session.makeSnapshot())
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["tabOrder"] = [second.id, UUID(), first.id, second.id].map(\.uuidString)
        let modified = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: modified)
        #expect(decoded.tabs.map(\.id) == [second.id, first.id, unlisted.id])
    }

    @Test("a root field this build does not know survives a restore and a save")
    func aRootFieldThisBuildDoesNotKnow_survivesARestoreAndSave() throws {
        let session = WorkspaceSession()
        session.openTabInActiveScope()
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session.makeSnapshot())) as? [String: Any]
        )
        let oldPath = URL(fileURLWithPath: "/tmp/snapshot-old")
        let newPath = URL(fileURLWithPath: "/tmp/snapshot-new")
        json["recentProjectPaths"] = [oldPath.absoluteString]
        // A newer Weir's field, as a rollback finds it.
        json["projectViewsFromTheFuture"] = ["kept": true]
        json["futureCloudSyncToken"] = "abc-123-def"
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.unknownFields["futureCloudSyncToken"] == .string("abc-123-def"))
        #expect(Set(decoded.unknownFields.keys) == ["projectViewsFromTheFuture", "futureCloudSyncToken"])

        let restored = WorkspaceSession()
        restored.restore(from: decoded)
        #expect(restored.recentProjectPaths == [oldPath])
        restored.recentProjectPaths = [newPath]
        let saved = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.makeSnapshot())) as? [String: Any]
        )

        #expect((saved["projectViewsFromTheFuture"] as? [String: Any])?["kept"] as? Bool == true)
        #expect(saved["futureCloudSyncToken"] as? String == "abc-123-def")
        #expect(saved["recentProjectPaths"] as? [String] == [newPath.absoluteString])
    }

    @Test("a second restore replaces what the first carried rather than adding to it")
    func aSecondRestore_replacesTheCarriedRootFields() throws {
        let session = WorkspaceSession()
        session.openTabInActiveScope()
        let plain = try JSONEncoder().encode(session.makeSnapshot())
        let base = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        func snapshot(keeping field: String, value: String) throws -> SessionSnapshot {
            var json = base
            json[field] = value
            return try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let restored = WorkspaceSession()
        func saved() throws -> [String: Any] {
            let data = try JSONEncoder().encode(restored.makeSnapshot())
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        try restored.restore(from: snapshot(keeping: "futureA", value: "first"))
        let first = try saved()
        #expect(first["futureA"] as? String == "first")
        #expect(first["futureB"] == nil)

        try restored.restore(from: snapshot(keeping: "futureB", value: "second"))
        let second = try saved()
        #expect(second["futureA"] == nil)
        #expect(second["futureB"] as? String == "second")

        try restored.restore(from: JSONDecoder().decode(SessionSnapshot.self, from: plain))
        let third = try saved()
        #expect(third["futureA"] == nil)
        #expect(third["futureB"] == nil)
        #expect(restored.makeSnapshot().unknownFields.isEmpty)
    }

    @Test("a known key set among the unknown fields is written from its field alone")
    func aKnownKeyAmongTheUnknownFields_isNotWritten() throws {
        let session = WorkspaceSession()
        session.openTabInActiveScope()
        let path = URL(fileURLWithPath: "/tmp/snapshot-recent")
        session.recentProjectPaths = [path]
        var snapshot = session.makeSnapshot()
        snapshot.unknownFields["recentProjectPaths"] = .string("stale")
        snapshot.unknownFields["futureField"] = .string("retained")
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        #expect(object["recentProjectPaths"] as? [String] == [path.absoluteString])
        #expect(object["futureField"] as? String == "retained")
    }
}
