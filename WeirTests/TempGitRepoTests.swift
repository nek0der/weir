// TempGitRepoTests.swift
// Weir — every repository the git fixture makes, its clones included, gets the fixture's local git overrides.

import Foundation
import Testing
@testable import Weir

@Suite(.timeLimit(.minutes(1)))
struct TempGitRepoTests {
    /// These are the settings `configureForTests` writes that the clones
    /// once lacked.
    static let isolation = [("core.autocrlf", "false"), ("tag.gpgsign", "false"), ("core.excludesFile", "/dev/null")]

    @Test func theRepositoryAndItsTeammatesClone_getTheLocalOverrides() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try await expectLocalOverrides(in: repo.url)

        let bare = try await repo.addBareOrigin()
        let pushedTip = try await repo.advance(bare)
        let clone = repo.scratch.appendingPathComponent("\(repo.url.lastPathComponent)-clone")
        try #require(try await TempGitRepo.git(["rev-parse", "HEAD"], in: clone) == pushedTip)
        try await expectLocalOverrides(in: clone)
    }

    @Test func aFailedSeedCommit_removesTheRepositoryScratch() async throws {
        let arguments = ["commit", "--not-a-git-commit-option"]
        var attemptedScratch: URL?
        defer {
            if let attemptedScratch {
                try? FileManager.default.removeItem(at: attemptedScratch)
            }
        }

        do {
            let repo = try await TempGitRepo.make { url in
                attemptedScratch = url.deletingLastPathComponent()
                let worktree = try await TempGitRepo.git(["rev-parse", "--is-inside-work-tree"], in: url)
                try #require(worktree == "true")
                try await TempGitRepo.git(arguments, in: url)
            }
            repo.cleanup()
            Issue.record("The invalid commit unexpectedly succeeded")
        } catch let failure as TempGitRepo.GitFailure {
            #expect(failure.arguments == arguments)
        }

        let scratch = try #require(attemptedScratch)
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

    private func expectLocalOverrides(in directory: URL) async throws {
        for (key, value) in Self.isolation {
            #expect(
                try await TempGitRepo.git(["config", "--local", "--get", key], in: directory) == value,
                "\(directory.lastPathComponent): \(key)"
            )
        }
    }
}
