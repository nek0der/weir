// ForgeResolverTests.swift
// Weir — host extraction and forge classification.
//
// Everything here sits on the path that decides whether we shell out
// to a CLI at all: a wrong answer either spawns processes for a host
// we cannot serve, or silently disables the feature for one we can.
//
// Host extraction and the heuristic are pure, and carry no tag. The
// remote-priority tests run `git` in a temp repository, so they are
// tagged `.smoke` individually.

import Foundation
import os
import Testing
@testable import Weir

@Suite("ForgeResolver")
struct ForgeResolverTests {

    // MARK: - Host extraction

    @Test(
        "extracts host from the URL forms git accepts",
        arguments: [
            ("https://github.com/nek0der/weir.git", "github.com"),
            ("https://gitlab.com/acme/app.git", "gitlab.com"),
            // scp-like syntax has no scheme, so URLComponents reports
            // no host and the fallback parser has to take over.
            ("git@github.com:nek0der/weir.git", "github.com"),
            ("git@gitlab.example.com:acme/app.git", "gitlab.example.com"),
            // No user component.
            ("github.com:nek0der/weir.git", "github.com"),
            ("ssh://git@github.com:22/nek0der/weir.git", "github.com"),
            // Host casing is normalized so cache keys collapse.
            ("https://GitHub.com/nek0der/weir.git", "github.com"),
            (" \t git@GitLab.com:acme/app.git \t", "gitlab.com")
        ]
    )
    func host_extractsFromRemoteURL(raw: String, expected: String) {
        #expect(ForgeResolver.host(fromRemoteURL: raw) == expected)
    }

    @Test(
        "returns nil for remotes with no host",
        arguments: [
            "",
            "   ",
            // A local path remote is legitimate and has no forge.
            "/Users/me/repo",
            "../sibling-repo",
            // This parses as a URL, but its authority is empty. The scp
            // parser would read the scheme as the hostname and report a
            // forge host of "file", costing two probe spawns to rule out.
            "file:///srv/repo.git",
        ]
    )
    func host_returnsNilWhenAbsent(raw: String) {
        #expect(ForgeResolver.host(fromRemoteURL: raw) == nil)
    }

    // MARK: - Classification

    @Test(
        "classifies hosts that name themselves",
        arguments: [
            ("github.com", ForgeKind.gitHub),
            ("gitlab.com", ForgeKind.gitLab),
            // The near-universal convention for enterprise installs.
            ("github.acme.com", ForgeKind.gitHub),
            ("gitlab.acme.com", ForgeKind.gitLab),
        ]
    )
    func heuristicKind_matchesNamedHosts(host: String, expected: ForgeKind) {
        #expect(ForgeResolver.heuristicKind(host: host) == expected)
    }

    /// These must fall through to the authentication probe rather than
    /// being guessed. `git.acme.com` is the common shape for both
    /// GitHub Enterprise and self-hosted GitLab, so guessing either way
    /// would be wrong half the time.
    @Test(
        "leaves ambiguous hosts unclassified for the auth probe",
        arguments: [
            "git.acme.com",
            "code.acme.com",
            "bitbucket.org",
            "codeberg.org",
            // Substring matches must not count: a host merely
            // containing the name is not the forge.
            "my-github-mirror.acme.com",
            "notgithub.com",
        ]
    )
    func heuristicKind_returnsNilForAmbiguousHosts(host: String) {
        #expect(ForgeResolver.heuristicKind(host: host) == nil)
    }

    // MARK: - Remote selection

    /// The remote a fork-based checkout resolves to.
    ///
    /// `origin` is the contributor's own fork and `upstream` the
    /// project it was forked from, so reading them in dictionary order
    /// — or in any order that puts `origin` first — would classify by
    /// the wrong host whenever the two live on different forges. We
    /// follow `gh`'s own priority so we agree with the tool we are
    /// about to invoke.
    ///
    /// The temporary repository exercises the actual config read and the
    /// working-directory cache across an explicit invalidation.
    @Test(
        "a fork resolves by its upstream, not its origin",
        .tags(.smoke)
    )
    func forge_prefersUpstreamOverOrigin() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try await repo.git(["remote", "add", "origin", "https://gitlab.com/me/weir.git"])
        let reads = Recorded<[URL]>([])
        let none = ToolLocator(known: ["gh": nil, "glab": nil])
        let resolver = ForgeResolver(locator: none) { arguments, directory in
            reads.update { $0.append(directory) }
            return await PRStatusFetcher.liveGit(arguments, directory)
        }
        #expect(await resolver.forge(for: repo.url) == .gitLab)

        try await repo.git(["remote", "add", "upstream", "https://github.com/nek0der/weir.git"])
        #expect(await resolver.forge(for: repo.url) == .gitLab)
        #expect(reads.value == [repo.url])

        await resolver.invalidate()
        #expect(await resolver.forge(for: repo.url) == .gitHub)
        #expect(reads.value == [repo.url, repo.url])
    }

    @Test func usableRemotesFollowTheNamedPriorityThenAlphabeticalOrder() {
        let remotes = [
            "z": "git@gitlab.com:team/last.git",
            "origin": "git@github.com:team/origin.git",
            "a": "git@github.com:team/first.git",
            "github": "git@github.com:team/github.git",
            "upstream": "git@gitlab.com:team/upstream.git",
            "local": "/tmp/forge-local"
        ]
        #expect(ForgeResolver.remotesByPriority(remotes).map(\.name) == ["upstream", "github", "origin", "a", "z"])
    }

    @Test func invalidationDuringRemoteReadDoesNotCacheItsOldForge() async throws {
        let gate = Gate<ToolResult>()
        let calls = Recorded(0)
        let resolver = ForgeResolver(locator: ToolLocator(known: ["gh": nil, "glab": nil])) { _, _ in
            calls.update { $0 += 1 }
            if calls.value == 1 {
                return await gate.wait()
            }
            return ToolResult(exitCode: 0, stdout: "remote.origin.url https://gitlab.com/acme/app.git\n", stderr: "")
        }
        let folder = URL(fileURLWithPath: "/nonexistent/forge-checkout")
        let old = ToolResult(exitCode: 0, stdout: "remote.origin.url https://github.com/acme/app.git\n", stderr: "")
        async let before = resolver.answer(for: folder)
        defer { gate.open(with: old) }
        try await gate.waitUntilRequested()

        await resolver.invalidate()
        gate.open(with: old)

        #expect(await before == .known(.gitHub))
        #expect(await resolver.answer(for: folder) == .known(.gitLab))
        #expect(await resolver.answer(for: folder) == .known(.gitLab))
        #expect(calls.value == 2)
    }

    /// Remotes that could not be read are no answer, and are not kept: the
    /// next ask reads them again rather than take the checkout for one with
    /// no forge.
    @Test("remotes that could not be read are no answer, asked again next time")
    func answer_unreadRemotes_isUnavailable_andNotKept() async {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let resolver = ForgeResolver(locator: ToolLocator()) { _, _ in
            let read = reads.withLock { reads in
                reads += 1
                return reads
            }
            return read == 1 ? nil : ToolResult(exitCode: 0, stdout: "remote.origin.url git@github.com:acme/app.git\n", stderr: "")
        }
        let folder = URL(fileURLWithPath: "/nonexistent/checkout")
        #expect(await resolver.answer(for: folder) == .unavailable)
        #expect(await resolver.answer(for: folder) == .known(.gitHub))
        #expect(reads.withLock { $0 } == 2)
    }

    /// A checkout with no remote, or one on a host no forge serves, is a
    /// known no, not a read that failed. It is read again on the next ask,
    /// so a remote added since shows its pull request without a Refresh.
    @Test("no remote, or a host no forge serves, is a known no, read again next time", arguments: [
        "",
        "remote.origin.url git@example.org:acme/app.git\n"
    ])
    func answer_noForge_isKnown_andReadAgain(remotes: String) async {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let none = ToolLocator(known: ["gh": nil, "glab": nil])
        let resolver = ForgeResolver(locator: none) { _, _ in
            reads.withLock { $0 += 1 }
            return ToolResult(exitCode: remotes.isEmpty ? 1 : 0, stdout: remotes, stderr: "")
        }
        let folder = URL(fileURLWithPath: "/nonexistent/checkout")
        #expect(await resolver.answer(for: folder) == .known(nil))
        #expect(await resolver.answer(for: folder) == .known(nil))
        #expect(reads.withLock { $0 } == 2)
    }

    /// A checkout with no remote must resolve to nil so the syncer
    /// stops there instead of spawning a CLI that can only fail.
    @Test(
        "a checkout with no remote resolves to no forge",
        .tags(.smoke)
    )
    func forge_noRemote_isNil() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try await withTempDir { directory in
            let executable = directory.appendingPathComponent("forge-probe")
            let probeLog = directory.appendingPathComponent("probe-called")
            // The marker is beside this script regardless of the probe's cwd.
            let script = #"""
            #!/bin/sh
            printf '%s\n' "$@" >> "${0%/*}/probe-called"
            exit 1
            """#
            try Data((script + "\n").utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let locator = ToolLocator(known: ["gh": executable, "glab": executable])
            let resolver = ForgeResolver(locator: locator)
            #expect(await resolver.isAuthenticated(kind: .gitHub, host: "probe.invalid") == false)
            let invocation = try String(contentsOf: probeLog, encoding: .utf8)
            #expect(invocation == "auth\ntoken\n--hostname\nprobe.invalid\n")
            try FileManager.default.removeItem(at: probeLog)

            #expect(await resolver.answer(for: repo.url) == .known(nil))
            #expect(!FileManager.default.fileExists(atPath: probeLog.path))

            try await repo.git(["remote", "add", "origin", "https://github.com/acme/app.git"])
            #expect(await resolver.forge(for: repo.url) == .gitHub)
            await resolver.invalidate()
            #expect(await resolver.forge(for: repo.url) == .gitHub)
            #expect(!FileManager.default.fileExists(atPath: probeLog.path))
        }
    }
}
