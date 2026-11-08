// PullRequestCheckoutDecodeTests.swift
// Weir — reading gh's and glab's answers about one pull request and the open ones, for a worktree made from one.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct PullRequestCheckoutDecodeTests {
    @Test func gh_aRequestOfTheRepositoryItself() throws {
        let json = """
        {"number":12,"title":"Fix login","state":"OPEN","headRefName":"fix/login",
         "headRefOid":"c0ffee","isCrossRepository":false,"headRepositoryOwner":{"login":"acme"}}
        """
        let head = try #require(ForgePullRequests.decode(stdout: json, forge: .gitHub))
        #expect(head == PullRequestHead(
            number: 12,
            title: "Fix login",
            state: .open,
            headBranch: "fix/login",
            headCommit: "c0ffee",
            forkOwner: nil
        ))
    }

    @Test func gh_aRequestFromAFork_namesItsOwner_andAClosedOneReadsClosed() throws {
        let json = """
        {"number":3,"title":"Typo","state":"CLOSED","headRefName":"main",
         "headRefOid":"abc","isCrossRepository":true,"headRepositoryOwner":{"login":"alice"}}
        """
        let head = try #require(ForgePullRequests.decode(stdout: json, forge: .gitHub))
        #expect(head == PullRequestHead(
            number: 3, title: "Typo", state: .closed, headBranch: "main", headCommit: "abc", forkOwner: "alice"
        ))
        #expect(head.isFromFork)
    }

    @Test func glab_aRequestFromAFork_isOneWhoseSourceProjectIsAnother() throws {
        let json = """
        {"iid":9,"title":"Docs","state":"merged","source_branch":"docs","sha":"def",
         "source_project_id":2,"target_project_id":1,"author":{"username":"bob"},"web_url":"https://gitlab.com/x/-/merge_requests/9"}
        """
        let head = try #require(ForgePullRequests.decode(stdout: json, forge: .gitLab))
        #expect(head == PullRequestHead(
            number: 9, title: "Docs", state: .merged, headBranch: "docs", headCommit: "def", forkOwner: "bob"
        ))
    }

    @Test func glab_aRequestOfTheProjectItself_hasNoFork() throws {
        let json = #"{"iid":4,"title":"t","state":"opened","source_branch":"b","source_project_id":1,"target_project_id":1}"#
        let head = try #require(ForgePullRequests.decode(stdout: json, forge: .gitLab))
        #expect(head == PullRequestHead(
            number: 4, title: "t", state: .open, headBranch: "b", headCommit: nil, forkOwner: nil
        ))
    }

    @Test func aList_readsEachRequest_andALineBeforeItIsLeftOut() {
        let stdout = """
        A new release of gh is available
        [{"number":1,"title":"a","state":"OPEN","headRefName":"a","isCrossRepository":false},
         {"number":2,"title":"b","state":"OPEN","headRefName":"b","isCrossRepository":true,"headRepositoryOwner":{"login":"c"}}]
        """
        let heads = ForgePullRequests.decodeList(stdout: stdout, forge: .gitHub)
        #expect(heads == [
            PullRequestHead(number: 1, title: "a", state: .open, headBranch: "a", headCommit: nil, forkOwner: nil),
            PullRequestHead(number: 2, title: "b", state: .open, headBranch: "b", headCommit: nil, forkOwner: "c")
        ])
        let gitLab = """
        [{"iid":6,"title":"First MR","state":"opened","source_branch":"first","sha":"a6","source_project_id":1,"target_project_id":1},
         {"iid":3,"title":"Fork MR","state":"merged","source_branch":"fork","source_project_id":2,
          "target_project_id":1,"author":{"username":"lee"}}]
        """
        #expect(ForgePullRequests.decodeList(stdout: gitLab, forge: .gitLab) == [
            PullRequestHead(number: 6, title: "First MR", state: .open, headBranch: "first", headCommit: "a6", forkOwner: nil),
            PullRequestHead(number: 3, title: "Fork MR", state: .merged, headBranch: "fork", headCommit: nil, forkOwner: "lee")
        ])
        #expect(ForgePullRequests.decodeList(stdout: "[]", forge: .gitHub) == [])
        #expect(ForgePullRequests.decodeList(stdout: "[]", forge: .gitLab) == [])
    }

    @Test(arguments: [
        ("printf '[]'; printf 'Could not connect\\n' >&2; exit 1", PullRequestListError.commandFailed),
        ("printf '[invalid]'", .invalidResponse)
    ])
    func aListReportsProcessAndDecodeFailures(_ command: String, expected: PullRequestListError) async throws {
        try await withTempDir { directory in
            let executable = directory.appendingPathComponent("gh")
            try AgentCatalogFixture.makeExecutable(executable, script: "#!/bin/sh\n\(command)\n")
            let locator = ToolLocator(known: ["gh": executable])
            let reader = ForgePullRequests(resolver: ForgeResolver(locator: locator), locator: locator)
            await #expect(throws: expected) {
                try await reader.openPullRequests(in: .fixture, repoRoot: directory)
            }
        }
    }

    struct LookupCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        var forge: ForgeKind = .gitHub
        var number = 5
        var result: ToolResult?
        let expected: PullRequestLookup
    }

    static let lookups = [
        LookupCase(
            testDescription: "GitHub reports a missing pull request", number: 99,
            result: ToolResult(exitCode: 1, stdout: "", stderr: "GraphQL: Could not resolve to a PullRequest with the number of 99."),
            expected: .notFound(99)
        ),
        LookupCase(
            testDescription: "GitLab reports a missing merge request", forge: .gitLab,
            result: ToolResult(exitCode: 1, stdout: "", stderr: "ERROR: 404 Not Found"),
            expected: .notFound(5)
        ),
        LookupCase(
            testDescription: "GitHub network error",
            result: ToolResult(exitCode: 1, stdout: "", stderr: "error connecting to api.github.com\n"),
            expected: .failed("error connecting to api.github.com")
        ),
        LookupCase(testDescription: "tool did not finish", expected: .failed("")),
        LookupCase(
            testDescription: "unreadable GitHub success",
            result: ToolResult(exitCode: 0, stdout: "{}", stderr: ""),
            expected: .failed("")
        ),
        LookupCase(
            testDescription: "unreadable GitLab success", forge: .gitLab,
            result: ToolResult(exitCode: 0, stdout: #"{"iid":"bad"}"#, stderr: ""),
            expected: .failed("")
        ),
        LookupCase(
            testDescription: "valid GitLab success", forge: .gitLab,
            result: ToolResult(
                exitCode: 0,
                stdout: #"{"iid":5,"title":"MR Five","state":"opened","source_branch":"topic","sha":"abc"}"#,
                stderr: ""
            ),
            expected: .found(PullRequestHead(
                number: 5,
                title: "MR Five",
                state: .open,
                headBranch: "topic",
                headCommit: "abc",
                forkOwner: nil
            ))
        )
    ]

    @Test(arguments: lookups)
    func aLookupKeepsItsHeadOrClassifiesItsFailure(_ scenario: LookupCase) {
        #expect(ForgePullRequests.lookup(scenario.result, number: scenario.number, forge: scenario.forge) == scenario.expected)
    }
}
