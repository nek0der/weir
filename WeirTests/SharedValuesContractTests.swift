// SharedValuesContractTests.swift
// Weir — the values the app and the Rust crates each define, checked against the one file both read.
//
// `rust/fixtures/contract/shared-values.json` is also read by the bridge's
// `contract_tests`, so a value changed on one side fails that side's tests
// until the file, and with it the other side, changes too.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
@Suite(.disabled(if: !RepoFixture.hasLocalRepo, "the shared fixtures are in the source tree"))
struct SharedValuesContractTests {
    struct SharedValues: Decodable {
        let maximumDecisionBytes: Int
        let maximumHookInputBytes: Int
        let maximumProjectionInputBytes: Int
        let maximumTitleBytes: Int
        let worktreeRoutingFileName: String
        let paneIdentifierVariable: String
        let codexTurnEndEvent: String
        let atWorkStates: [String]
        let notAtWorkStates: [String]
        let worktreeFolders: WorktreeFolders
        let gitRepositoryVariables: [String]
        let usageLimitScopes: [String]
        let usageWindows: UsageWindows
    }

    struct WorktreeFolders: Decodable {
        let projectRoot: String
        let customParent: String
        let cases: [WorktreeFolderCase]
        /// Branches whose worktree has no folder of its own.
        let noFolderBranches: [String]
    }

    struct UsageWindows: Decodable {
        let fiveHour: String
        let sevenDay: String
        let modelWeekly: [String]
        let minutesPrefix: String
    }

    struct WorktreeFolderCase: Decodable {
        let branch: String
        let siblingPrefixed: String
        let insideHidden: String
        let custom: String
    }

    private static func sharedValues() throws -> SharedValues {
        let root = try #require(RepoFixture.weirRoot)
        let data = try Data(contentsOf: root.appendingPathComponent("rust/fixtures/contract/shared-values.json"))
        return try JSONDecoder().decode(SharedValues.self, from: data)
    }

    @Test func theLimits_areTheOnesTheBrokerAndTheBridgeEnforce() throws {
        let shared = try Self.sharedValues()
        #expect(ApprovalResolution.maximumEncodedBytes == shared.maximumDecisionBytes)
        #expect(AgentIntegrationConfiguration.maximumHookInputBytes == shared.maximumHookInputBytes)
        #expect(AgentProjectionAdapter.inputLimitBytes == shared.maximumProjectionInputBytes)
        // The buffer a resolved title is written into holds the longest
        // title the core returns.
        #expect(WeirRustTitleResolver.outputCapacity == shared.maximumTitleBytes)
    }

    @Test func theRepositoryVariables_areTheOnesTheHookClears() throws {
        let listed = try Self.sharedValues().gitRepositoryVariables
        #expect(Set(listed).count == listed.count, "no name twice")
        #expect(GitProcess.repositoryVariables == Set(listed))
    }

    @Test func theUsageNames_areTheOnesTheRustModelWrites() throws {
        let shared = try Self.sharedValues()
        #expect(shared.usageLimitScopes.compactMap(UsageLimitScope.init(rawValue:)).count == shared.usageLimitScopes.count)
        let scopes: [UsageLimitScope] = [.account, .upstream, .model]
        #expect(scopes.map(\.rawValue) == shared.usageLimitScopes)
        let windows = shared.usageWindows
        #expect(PlanUsageWindow.fiveHour == windows.fiveHour)
        #expect(PlanUsageWindow.sevenDay == windows.sevenDay)
        #expect([PlanUsageWindow.sevenDayOpus, PlanUsageWindow.sevenDaySonnet] == windows.modelWeekly)
        #expect(PlanUsageWindow.minutesPrefix == windows.minutesPrefix)
        // A limit with no scope of its own is the model's for a model's
        // weekly window, and the account's for any other.
        for window in windows.modelWeekly {
            #expect(UsageLimit(window: window).scope == .model, "\(window)")
        }
        #expect(UsageLimit(window: windows.fiveHour).scope == .account)
        // A window named by its length alone reads back as a length, not
        // as the plain usage limit.
        let english = Locale(identifier: "en")
        let byLength = PlanUsageText.windowName("\(windows.minutesPrefix)1440", locale: english).resolved(in: english)
        #expect(byLength.hasSuffix(" limit") && byLength != "Usage limit")
    }

    @Test func theNames_areTheOnesTheHookReads() throws {
        let shared = try Self.sharedValues()
        #expect(WorktreeRouting.fileName == shared.worktreeRoutingFileName)
        #expect(PaneShellEnvironment.paneIDVariable == shared.paneIdentifierVariable)
        let env = PaneShellEnvironment.variables(
            paneID: UUID(),
            shimDirectories: [],
            zdotdir: nil,
            basePath: "/usr/bin"
        )
        #expect(env[shared.paneIdentifierVariable] != nil)
    }

    @Test func theRolloutWatcher_looksForTheEventTheCrateReads() throws {
        #expect(try Self.sharedValues().codexTurnEndEvent == RolloutReader.turnEndEvent)
    }

    @Test func theWorktreeFolders_areTheOnesTheHookMakes() throws {
        let folders = try Self.sharedValues().worktreeFolders
        #expect(!folders.cases.isEmpty)
        let customParent = URL(fileURLWithPath: folders.customParent)
        for folder in folders.cases {
            let leaf = BranchNameSuggester.folderLeaf(of: folder.branch)
            let placements: [(WorktreePlacement, String)] = [
                (.siblingPrefixed, folder.siblingPrefixed),
                (.insideHidden, folder.insideHidden),
                (.custom(customParent), folder.custom)
            ]
            for (placement, expected) in placements {
                let project = Project(
                    id: UUID(),
                    name: "repo",
                    rootURL: URL(fileURLWithPath: folders.projectRoot),
                    worktrees: [],
                    worktreePlacement: placement
                )
                #expect(project.resolvedWorktreeURL(branchLeaf: leaf).path == expected, "\(folder.branch)")
                #expect(project.worktreeURL(forBranch: folder.branch)?.path == expected, "\(folder.branch)")
            }
        }
        #expect(!folders.noFolderBranches.isEmpty)
        for branch in folders.noFolderBranches {
            for placement in [WorktreePlacement.siblingPrefixed, .insideHidden, .custom(customParent)] {
                let project = Project(
                    id: UUID(),
                    name: "repo",
                    rootURL: URL(fileURLWithPath: folders.projectRoot),
                    worktrees: [],
                    worktreePlacement: placement
                )
                #expect(project.worktreeURL(forBranch: branch) == nil, "\(branch.debugDescription)")
            }
        }
    }

    @Test func theMidTurnStates_areTheOnesTheHookCountsAsAtWork() throws {
        let shared = try Self.sharedValues()
        let atWork = try shared.atWorkStates.map { try #require(AgentState(rawValue: $0), "\($0)") }
        let notAtWork = try shared.notAtWorkStates.map { try #require(AgentState(rawValue: $0), "\($0)") }
        for state in atWork {
            #expect(state.isMidTurn, "\(state)")
        }
        for state in notAtWork {
            #expect(!state.isMidTurn, "\(state)")
        }
        // Every state this build knows is on one side or the other, so a new
        // one has to be placed in the file before either side can ship it.
        #expect(Set(atWork + notAtWork) == Set(AgentState.allCases))
    }
}
