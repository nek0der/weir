// PullRequestCheckoutRulesTests.swift
// Weir — the pull request number as typed, and the local branch a pull request's worktree checks out.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct PullRequestCheckoutRulesTests {
    @Test(arguments: [
        ("12", 12), ("#12", 12), (" 7 ", 7), ("!34", 34),
        ("https://github.com/acme/app/pull/128", 128),
        ("https://github.com/acme/app/pull/128/files", 128),
        ("https://gitlab.com/acme/app/-/merge_requests/9", 9)
    ])
    func aNumberALinkOrAMark_readsAsTheNumber(text: String, number: Int) {
        #expect(PullRequestNumber.parse(text) == number)
    }

    @Test(arguments: ["", "#", "0", "-3", "12a", "１２", "abc", "https://github.com/acme/app/issues/5"])
    func anythingElse_readsAsNone(text: String) {
        #expect(PullRequestNumber.parse(text) == nil)
    }

    private static let head = PullRequestHead.fixture(12, branch: "fix/login", commit: "c0ffee")

    struct CheckoutCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        var head = PullRequestCheckoutRulesTests.head
        var commit: String? = "c0ffee"
        let localTips: [String: String]
        var checkedOut: Set<String> = []
        let expected: PullRequestBranchChoice
    }

    static let checkoutCases = [
        CheckoutCase(
            testDescription: "head name is free",
            localTips: ["main": "aaa"], checkedOut: ["main"],
            expected: .newBranch("fix/login")
        ),
        CheckoutCase(
            testDescription: "head name already points to the commit",
            localTips: ["fix/login": "c0ffee"],
            expected: .existingBranch("fix/login")
        ),
        CheckoutCase(
            testDescription: "same-commit head is checked out elsewhere",
            localTips: ["fix/login": "c0ffee"], checkedOut: ["fix/login"],
            expected: .checkedOut("fix/login")
        ),
        CheckoutCase(
            testDescription: "fork's main conflicts with local main at another commit",
            head: .fixture(12, branch: "main", commit: "c0ffee", forkOwner: "alice"),
            localTips: ["main": "aaa"], checkedOut: ["main"],
            expected: .newBranch("pr/12")
        ),
        CheckoutCase(
            testDescription: "both the bare fallback and its first suffix are taken",
            localTips: ["fix/login": "aaa", "pr/12": "bbb", "pr/12-2": "ccc"],
            expected: .newBranch("pr/12-3")
        ),
        CheckoutCase(
            testDescription: "fallback already points to the commit",
            localTips: ["fix/login": "aaa", "pr/12": "c0ffee"],
            expected: .existingBranch("pr/12")
        ),
        CheckoutCase(
            testDescription: "unknown commit cannot prove reuse",
            head: .fixture(12, branch: "fix/login"), commit: nil,
            localTips: ["fix/login": "c0ffee"],
            expected: .newBranch("pr/12")
        ),
        CheckoutCase(
            testDescription: "existing nested branch blocks its ancestor name",
            head: .fixture(12, branch: "fix", commit: "c"), commit: "c",
            localTips: ["fix/login": "x"],
            expected: .newBranch("pr/12")
        ),
        CheckoutCase(
            testDescription: "existing ancestor blocks the nested name",
            head: .fixture(12, branch: "feat/x/y", commit: "c"), commit: "c",
            localTips: ["feat/x": "x"],
            expected: .newBranch("pr/12")
        ),
        CheckoutCase(
            testDescription: "ancestor of every fallback leaves the last for Git to refuse",
            head: .fixture(12, branch: "fix", commit: "c"), commit: "c",
            localTips: ["fix/login": "x", "pr": "y"],
            expected: .newBranch("pr/12-\(PullRequestBranchChoice.maximumSuffix)")
        )
    ]

    @Test(arguments: checkoutCases)
    func choosesTheLocalBranchForTheRequest(_ scenario: CheckoutCase) {
        #expect(PullRequestBranchChoice.choose(
            for: scenario.head, commit: scenario.commit, localTips: scenario.localTips, checkedOut: scenario.checkedOut
        ) == scenario.expected)
    }

    @Test func everyNameTaken_endsAtTheLastForGitToRefuse() {
        var tips = ["fix/login": "x", "pr/12": "x"]
        for suffix in 2...PullRequestBranchChoice.maximumSuffix {
            tips["pr/12-\(suffix)"] = "x"
        }
        let choice = PullRequestBranchChoice.choose(for: Self.head, commit: "c0ffee", localTips: tips, checkedOut: [])
        #expect(choice == .newBranch("pr/12-\(PullRequestBranchChoice.maximumSuffix)"))
    }

    @Test(arguments: [
        ("https://github.com/Acme/App/pull/12", "github.com/acme/app" as String?),
        ("https://gitlab.com/group/sub/app/-/merge_requests/3", "gitlab.com/group/sub/app"),
        ("#12", nil),
        ("12", nil)
    ])
    func aLinksRepository_isItsHostAndPath(link: String, repository: String?) {
        #expect(PullRequestNumber.repository(in: link) == repository)
    }

    @Test(arguments: [
        ("https://github.com/acme/app.git", "github.com/acme/app" as String?),
        ("git@github.com:acme/app", "github.com/acme/app"),
        ("ssh://git@gitlab.acme.io/group/sub/app.git/", "gitlab.acme.io/group/sub/app"),
        ("/srv/app.git", nil)
    ])
    func aRemotesRepository_isItsHostAndPath(remote: String, repository: String?) {
        #expect(ForgeResolver.repository(fromRemoteURL: remote) == repository)
    }

    @Test(arguments: [
        (ForgeKind.gitHub, "refs/pull/7/head"),
        (.gitLab, "refs/merge-requests/7/head")
    ])
    func theForgesRef_forEachForge(forge: ForgeKind, ref: String) {
        #expect(forge.headRef(of: 7) == ref)
    }
}
