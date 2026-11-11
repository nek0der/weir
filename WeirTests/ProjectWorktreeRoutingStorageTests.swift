// ProjectWorktreeRoutingStorageTests.swift
// Weir — a project's worktree routing reads every state.json shape and writes one an earlier build still reads.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Project worktree routing storage")
struct ProjectWorktreeRoutingStorageTests {
    /// The keys a project kept its routing under before the map, each
    /// with its agent.
    private static let legacyKeys: [(kind: AgentKind, key: String)] = [
        (.claude, "routeClaudeWorktrees"),
        (.codex, "routeCodexWorktrees"),
        (.antigravity, "routeAntigravityWorktrees")
    ]

    /// A project as state.json holds it, with `fields` added.
    private static func json(_ fields: [String: Any]) throws -> Data {
        var object: [String: Any] = [
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Test",
            "rootURL": "file:///tmp/test",
            "worktrees": [Any]()
        ]
        object.merge(fields) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// The routing an earlier build reads from `data`: each legacy key, or
    /// on when it is absent, as its decoder had it.
    private static func legacyReading(_ data: Data) throws -> [AgentKind: Bool] {
        let object = try JSONObjectFixture.object(data)
        return Dictionary(uniqueKeysWithValues: legacyKeys.map { ($0.kind, object[$0.key] as? Bool ?? true) })
    }

    /// Every opt-out an agent with a toggle can have, one set of them at a time.
    private static var optOutSets: [Set<AgentKind>] {
        let toggled = AgentKind.allCases.filter { AgentProviderRegistry.hasWorktreePlacement($0) }
        return (0..<(1 << toggled.count)).map { mask in
            Set(toggled.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
        }
    }

    // MARK: - Reading

    /// Each legacy key absent, on, or off, in every combination: the agent
    /// routes unless its key says false, and an agent with no key routes.
    @Test func everyLegacyCombination_readsAsItsKeysSay() throws {
        let values: [Bool?] = [nil, true, false]
        for claude in values {
            for codex in values {
                for antigravity in values {
                    var fields: [String: Any] = [:]
                    for (key, value) in zip(Self.legacyKeys.map(\.key), [claude, codex, antigravity]) {
                        if let value {
                            fields[key] = value
                        }
                    }
                    let project = try JSONDecoder().decode(Project.self, from: Self.json(fields))
                    let label = "\(String(describing: claude)) \(String(describing: codex)) \(String(describing: antigravity))"
                    #expect(project.routesWorktrees(for: .claude) == (claude ?? true), "\(label)")
                    #expect(project.routesWorktrees(for: .codex) == (codex ?? true), "\(label)")
                    #expect(project.routesWorktrees(for: .antigravity) == (antigravity ?? true), "\(label)")
                    #expect(project.routesWorktrees(for: .opencode), "\(label)")
                }
            }
        }
    }

    /// A file with the map and no legacy keys, as a later build that stops
    /// writing them would leave it: the map decides, and an agent this build
    /// does not know keeps its value through a save.
    @Test func theMapAlone_decidesAndKeepsAnAgentThisBuildDoesNotKnow() throws {
        let project = try JSONDecoder().decode(Project.self, from: Self.json([
            "worktreeRouting": ["claude": false, "codex": true, "kiro": false]
        ]))
        #expect(!project.routesWorktrees(for: .claude))
        #expect(project.routesWorktrees(for: .codex))
        #expect(project.routesWorktrees(for: .antigravity))
        let routing = try #require(JSONObjectFixture.object(encoding: project)["worktreeRouting"] as? [String: Bool])
        #expect(routing == ["claude": false, "kiro": false])
    }

    /// A map of a shape this build cannot read costs only what it held: the
    /// project loads, with its legacy keys.
    @Test func aMapOfAnotherShape_costsOnlyTheMap() throws {
        let project = try JSONDecoder().decode(Project.self, from: Self.json([
            "routeCodexWorktrees": false,
            "worktreeRouting": ["claude": "off", "antigravity": false]
        ]))
        #expect(project.routesWorktrees(for: .claude))
        #expect(!project.routesWorktrees(for: .codex))
        #expect(project.routesWorktrees(for: .antigravity))
    }

    /// A null map reads as no opt-out, beside whatever the legacy keys say.
    @Test func aNullMap_readsAsNone() throws {
        let project = try JSONDecoder().decode(Project.self, from: Self.json([
            "routeAntigravityWorktrees": false,
            "worktreeRouting": NSNull()
        ]))
        #expect(project.routesWorktrees(for: .claude))
        #expect(project.routesWorktrees(for: .codex))
        #expect(!project.routesWorktrees(for: .antigravity))
        #expect(try JSONObjectFixture.object(encoding: project)["worktreeRouting"] as? [String: Bool] == ["antigravity": false])
    }

    /// A build from before the map changes a legacy key and carries the map
    /// it does not know through unchanged. The key is the newer word, so it
    /// wins: a Claude the person turned back on there stays on here.
    @Test func aLegacyKey_winsOverTheMapAnEarlierBuildCarriedThrough() throws {
        let turnedBackOn = try JSONDecoder().decode(Project.self, from: Self.json([
            "routeClaudeWorktrees": true,
            "routeCodexWorktrees": true,
            "routeAntigravityWorktrees": true,
            "worktreeRouting": ["claude": false]
        ]))
        #expect(turnedBackOn.routesWorktrees(for: .claude))
        let turnedOff = try JSONDecoder().decode(Project.self, from: Self.json([
            "routeClaudeWorktrees": true,
            "routeCodexWorktrees": false,
            "routeAntigravityWorktrees": true,
            "worktreeRouting": [String: Bool]()
        ]))
        #expect(!turnedOff.routesWorktrees(for: .codex))
    }

    // MARK: - Writing

    /// Every opt-out set comes back as it went: through this build, and
    /// through the legacy reading an earlier build gives the same file.
    @Test func everyOptOutSet_roundTrips_andReadsTheSameToAnEarlierBuild() throws {
        for optOuts in Self.optOutSets {
            var project = Project(name: "Test", rootURL: URL(fileURLWithPath: "/tmp/test"))
            for kind in optOuts {
                project.setRoutesWorktrees(false, for: kind)
            }
            let data = try JSONEncoder().encode(project)
            let decoded = try JSONDecoder().decode(Project.self, from: data)
            #expect(decoded == project, "\(optOuts)")
            for kind in AgentKind.allCases {
                #expect(decoded.routesWorktrees(for: kind) == !optOuts.contains(kind), "\(optOuts) \(kind)")
            }
            let legacy = try Self.legacyReading(data)
            for (kind, routes) in legacy {
                #expect(routes == project.routesWorktrees(for: kind), "\(optOuts) \(kind)")
            }
        }
    }

    /// The three legacy keys are always written, on or off, beside the map,
    /// so an earlier build never falls back to its default for one.
    @Test func theLegacyKeys_areAlwaysWritten() throws {
        let object = try JSONObjectFixture.object(encoding: Project(name: "Test", rootURL: URL(fileURLWithPath: "/tmp/test")))
        for (_, key) in Self.legacyKeys {
            #expect(object[key] as? Bool == true, "\(key)")
        }
        #expect(object["worktreeRouting"] as? [String: Bool] == [:])
    }

    // MARK: - The routing file

    /// The routing file names each agent with a toggle, routed or not, under
    /// its id, as it did when it listed Claude, Codex, and Antigravity by
    /// hand; an agent without one is left out, which the hook reads as routed.
    @Test func theRoutingFile_namesTheAgentsItAlwaysNamed() throws {
        for optOuts in Self.optOutSets {
            var project = Project(name: "Test", rootURL: URL(fileURLWithPath: "/tmp/test"))
            for kind in optOuts {
                project.setRoutesWorktrees(false, for: kind)
            }
            let routing = try #require(WorktreeRouting(projects: [project]).projects.first).routing
            #expect(routing == [
                "claude": !optOuts.contains(.claude),
                "codex": !optOuts.contains(.codex),
                "antigravity": !optOuts.contains(.antigravity),
                "kiro": !optOuts.contains(.kiro)
            ], "\(optOuts)")
        }
    }

    /// With no registry to read, the agents that had a toggle keep it, so the
    /// file still names them and a person's "off" still reaches the hook,
    /// and the setter still turns them off.
    @MainActor
    @Test func anEmptyRegistry_keepsTheToggleOfTheAgentsThatHadOne() throws {
        let noRegistry: (AgentKind) -> Bool = { kind in
            AgentProviderRegistry.hasWorktreePlacement(kind, isRegistryEmpty: true, has: { _, _ in false })
        }
        let session = WorkspaceSession()
        let project = Project(name: "Test", rootURL: URL(fileURLWithPath: "/tmp/test"))
        session.projects.append(project)
        for kind in AgentKind.allCases {
            session.setProjectRoutesWorktrees(project.id, for: kind, to: false, hasPlacement: noRegistry)
        }
        let saved = try #require(session.projects.first)
        let routing = try #require(WorktreeRouting(projects: [saved], hasPlacement: noRegistry).projects.first).routing
        #expect(routing == ["claude": false, "codex": false, "antigravity": false])
        #expect(Set(AgentKind.allCases.filter(noRegistry)) == [.claude, .codex, .antigravity])
    }

    /// An agent the project keeps out is named even when nothing says it
    /// has a toggle, so the file never drops a stored "off".
    @Test func anOptOut_isNamedWhateverTheCapabilitySays() throws {
        var project = Project(name: "Test", rootURL: URL(fileURLWithPath: "/tmp/test"))
        project.setRoutesWorktrees(false, for: .codex)
        let routing = try #require(WorktreeRouting(projects: [project], hasPlacement: { _ in false }).projects.first).routing
        #expect(routing == ["codex": false])
    }

    /// Which agents the file names comes from the capability, so an agent
    /// that gains a toggle is named without a change here.
    @Test func theRoutingFile_followsThePlacementCapability() throws {
        var project = Project(name: "Test", rootURL: URL(fileURLWithPath: "/tmp/test"))
        let included = try #require(WorktreeRouting(projects: [project], hasPlacement: { $0 == .opencode }).projects.first)
        #expect(included.routing == ["opencode": true])
        let excluded = try #require(WorktreeRouting(projects: [project], hasPlacement: { _ in false }).projects.first)
        #expect(excluded.routing.isEmpty)

        project.setRoutesWorktrees(false, for: .opencode)
        let routing = try #require(WorktreeRouting(projects: [project], hasPlacement: { $0 == .opencode }).projects.first).routing
        #expect(routing == ["opencode": false])
    }
}
