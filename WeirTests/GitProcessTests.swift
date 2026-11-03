// GitProcessTests.swift
// Weir — running `git`: its deadline, worktree removal, the main checkout, and a detached HEAD.
//
// The check against Weir's own checkout needs its `.git` directory and
// skips without it (`RepoFixture.hasLocalRepo`); the rest build their
// repositories with `TempGitRepo`.

import Foundation
import Testing
@testable import Weir

@Suite("GitProcess smoke", .tags(.smoke))
struct GitProcessSmokeTests {

    @Test(.disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func run_gitVersion_reportsGitVersionString() async throws {
        let root = try #require(RepoFixture.weirRoot)
        let result = try await GitProcess.run(["--version"], cwd: root)
        #expect(result.succeeded, "git --version should succeed: \(result.stderr)")
        #expect(result.stdout.contains("git version"))
    }

    @Test
    func removeWorktree_withInitializedSubmodule_requiresForce() async throws {
        let repository = try await TempGitRepo.make()
        let submodule = try await TempGitRepo.make()
        defer {
            repository.cleanup()
            submodule.cleanup()
        }

        let addSubmodule = try await GitProcess.run(
            [
                "-c", "protocol.file.allow=always", "submodule", "add", "--",
                submodule.url.path, "deps/submodule"
            ],
            cwd: repository.url
        )
        try #require(addSubmodule.succeeded, "git submodule add failed: \(addSubmodule.stderr)")
        let commit = try await GitProcess.run(
            ["commit", "-m", "Add test submodule"],
            cwd: repository.url
        )
        try #require(commit.succeeded, "git commit failed: \(commit.stderr)")
        let linkedPath = try await repository.addLinkedWorktree(branch: "linked")
        let initialize = try await GitProcess.run(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init"],
            cwd: linkedPath
        )
        try #require(initialize.succeeded, "git submodule update failed: \(initialize.stderr)")
        let linkedSubmodule = linkedPath.appendingPathComponent("deps/submodule")
        let localCommit = try await GitProcess.run(
            [
                "-c", "user.name=Weir Tests",
                "-c", "user.email=tests@weir.invalid",
                "commit", "--allow-empty", "-m", "Local-only submodule commit"
            ],
            cwd: linkedSubmodule
        )
        try #require(localCommit.succeeded, "local submodule commit failed: \(localCommit.stderr)")
        let resolveGitDirectory = try await GitProcess.run(
            ["rev-parse", "--absolute-git-dir"],
            cwd: linkedSubmodule
        )
        try #require(resolveGitDirectory.succeeded, "git-dir lookup failed: \(resolveGitDirectory.stderr)")
        let submoduleGitDirectory = resolveGitDirectory.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(FileManager.default.fileExists(atPath: submoduleGitDirectory))

        let regularRemoval = try await GitProcess.removeWorktree(
            repoRoot: repository.url,
            path: linkedPath,
            force: false
        )
        #expect(!regularRemoval.succeeded)
        #expect(regularRemoval.stderr.contains("working trees containing submodules"))

        let forcedRemoval = try await GitProcess.removeWorktree(
            repoRoot: repository.url,
            path: linkedPath,
            force: true
        )
        #expect(forcedRemoval.succeeded, "forced removal failed: \(forcedRemoval.stderr)")
        #expect(!FileManager.default.fileExists(atPath: submoduleGitDirectory))
    }

    @Test
    func gitBranch_takesANameThatLooksLikeAnOption_asAName() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        _ = try await GitProcess.run(["branch", "develop"], cwd: repo.url)
        // Whatever git makes of "-D" as a name, it is not `git branch -D develop`.
        _ = try await LiveGit().createBranch(repoRoot: repo.url, name: "-D", startPoint: "develop")
        #expect(try await LiveGit().createBranch(repoRoot: repo.url, name: "kept", startPoint: "develop").succeeded)
    }

    /// A tag of the same name turns git's short name for the branch into
    /// `heads/v1`, and the new worktree sheet would not find `v1` among the
    /// branches, nor name it as the branch checked out.
    @Test
    func listLocalBranches_namesABranchByItsOwnName_besideATagOfTheSameName() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        _ = try await GitProcess.run(["branch", "v1"], cwd: repo.url)
        _ = try await GitProcess.run(["tag", "v1"], cwd: repo.url)
        _ = try await GitProcess.run(["branch", "feat/nested"], cwd: repo.url)
        let branches = try await GitProcess.listLocalBranches(repoRoot: repo.url)
        #expect(branches.contains("v1"))
        #expect(branches.contains("feat/nested"))
        #expect(!branches.contains { $0.hasPrefix("heads/") })
        _ = try await GitProcess.run(["checkout", "-q", "v1"], cwd: repo.url)
        #expect(try await GitProcess.currentBranch(repoRoot: repo.url) == "v1")
        _ = try await GitProcess.run(["checkout", "-q", "--detach"], cwd: repo.url)
        #expect(try await GitProcess.currentBranch(repoRoot: repo.url) == nil)
    }

    /// Before the first commit git already names the branch the repository
    /// will have, but there is nothing yet to make a worktree from.
    @Test
    func currentBranch_isNil_beforeTheFirstCommit() async throws {
        let branch: String? = try await withTempDir { directory in
            _ = try await GitProcess.run(["init", "-q", "-b", "main"], cwd: directory)
            return try await GitProcess.currentBranch(repoRoot: directory)
        }
        #expect(branch == nil)
    }
}

/// A git run has a deadline, and the deadline holds whatever git does.
struct GitProcessDeadlineTests {
    /// A `git` that ignores SIGTERM and never finishes, as one waiting in a
    /// hook does.
    private func writeHangingGit(in directory: URL) throws -> GitExecutable {
        let script = directory.appendingPathComponent("git")
        try "#!/bin/sh\ntrap '' TERM\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return GitExecutable(url: script, leadingArguments: [])
    }

    @Test func aRunPastItsDeadline_isEndedAndThrows() async throws {
        try await withTempDir { directory in
            let git = try writeHangingGit(in: directory)
            let clock = SuspendingClock()
            let started = clock.now
            var thrown: (any Error)?
            do {
                _ = try await GitProcess.run(["status"], cwd: directory, timeout: .seconds(1), executable: git)
            } catch {
                thrown = error
            }
            // The run gives up 1 second for the deadline plus twice the
            // 2-second grace, 5 seconds, when something of the group outlives
            // SIGKILL. The bound is well short of the 30 the script sleeps
            // and leaves room for a busy CI runner.
            #expect(clock.now - started < .seconds(15), "the deadline and the grace, not the script's own end")
            guard case let .timedOut(seconds, _)? = thrown as? GitProcessError else {
                Issue.record("expected a timeout, got \(String(describing: thrown))")
                return
            }
            #expect(seconds == 1)
        }
    }

    /// Git starts a hook that ignores SIGTERM, while git itself ends on
    /// it: the hook is ended too, before the run returns, so nothing of it
    /// writes in a folder the caller clears and makes again.
    @Test func aRunPastItsDeadline_endsWhatItStarted_evenWhenThatIgnoresSIGTERM() async throws {
        try await withTempDir { directory in
            let pidFile = directory.appendingPathComponent("hook.pid")
            let script = directory.appendingPathComponent("git")
            try """
            #!/bin/sh
            sh -c 'trap "" TERM; echo $$ > "$1.tmp"; mv "$1.tmp" "$1"; while :; do sleep 1; done' hook '\(pidFile.path)' &
            sleep 30
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let git = GitExecutable(url: script, leadingArguments: [])

            var thrown: (any Error)?
            do {
                _ = try await GitProcess.run(["worktree", "add"], cwd: directory, timeout: .seconds(1), executable: git)
            } catch {
                thrown = error
            }

            guard case let .timedOut(_, hasProcessesLeft)? = thrown as? GitProcessError else {
                Issue.record("expected a timeout, got \(String(describing: thrown))")
                return
            }
            #expect(!hasProcessesLeft)
            let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(!ProcessLiveness.isLive(pid), "the hook is gone once the run returns")
        }
    }

    @Test func aTimeout_saysHowLongGitHad() {
        let message = GitProcessError.timedOut(seconds: 60).message
        #expect(message.resolved(in: Locale(identifier: "en")) == "git didn’t finish within 60 seconds.")
        #expect(message.resolved(in: Locale(identifier: "ja")) == "git が 60 秒以内に完了しませんでした。")
    }

    @Test func aOneSecondTimeout_saysSecondInTheSingular() {
        let message = GitProcessError.timedOut(seconds: 1).message
        #expect(message.resolved(in: Locale(identifier: "en")) == "git didn’t finish within 1 second.")
        #expect(message.resolved(in: Locale(identifier: "ja")) == "git が 1 秒以内に完了しませんでした。")
    }
}

@Suite("GitProcess resolveMainCheckout", .tags(.smoke))
struct GitProcessResolveMainCheckoutTests {

    @Test
    func resolveMainCheckout_returnsURLUnchanged_forNonGitDirectory() async throws {
        try await withTempDir { tmp in
            let resolved = await GitProcess.resolveMainCheckout(of: tmp)

            #expect(resolved.standardizedFileURL == tmp.standardizedFileURL)
        }
    }

    @Test
    func resolveMainCheckout_returnsURLUnchanged_forMainCheckoutRoot() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }

        let resolved = await GitProcess.resolveMainCheckout(of: repo.url)

        #expect(resolved.standardizedFileURL == repo.url.standardizedFileURL)
    }

    @Test
    func resolveMainCheckout_returnsURLUnchanged_forSubdirectoryOfMainCheckout() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let subdir = repo.url.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let resolved = await GitProcess.resolveMainCheckout(of: subdir)

        // Subdirectories under a working tree are an intentional
        // anchor — the resolver must not promote them.
        #expect(resolved.standardizedFileURL == subdir.standardizedFileURL)
    }

    @Test
    func resolveMainCheckout_promotesLinkedWorktreeRoot_toMainCheckout() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let linkedPath = try await repo.addLinkedWorktree(branch: "feature")

        let resolved = await GitProcess.resolveMainCheckout(of: linkedPath)

        #expect(resolved.standardizedFileURL == repo.url.standardizedFileURL)
    }
}

/// What a git run starts with, whoever opened Weir.
struct GitProcessEnvironmentTests {
    /// A `git` that writes its arguments and its `GIT_*` variables to
    /// `record`, one per line.
    private func writeRecordingGit(in directory: URL, record: URL) throws -> GitExecutable {
        let script = directory.appendingPathComponent("git")
        try """
        #!/bin/sh
        { printf '%s\\n' "$@"; env | grep '^GIT_' | sort; } > '\(record.path)'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return GitExecutable(url: script, leadingArguments: [])
    }

    /// A repository's own `core.fsmonitor` program is not started, and
    /// the variables the caller gives reach git.
    @Test func aRun_turnsOffFsmonitor_andPassesTheGivenVariables() async throws {
        try await withTempDir { directory in
            let record = directory.appendingPathComponent("record")
            let git = try writeRecordingGit(in: directory, record: record)
            let result = try await GitProcess.run(
                ["status"],
                cwd: directory,
                environment: ["GIT_TERMINAL_PROMPT": "0"],
                executable: git
            )
            #expect(result.succeeded)
            let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
            #expect(Array(lines.prefix(3)) == ["-c", "core.fsmonitor=false", "status"])
            #expect(lines.contains("GIT_TERMINAL_PROMPT=0"))
        }
    }

    /// The repository is the one at `cwd`: a variable of the shell that
    /// opened Weir naming another does not reach git, while the rest of its
    /// environment does, a fetch's certificates among it, and what the
    /// caller gives wins.
    @Test func theEnvironment_dropsInheritedRepositoryVariables() {
        let env = GitProcess.environment(
            inherited: [
                "GIT_DIR": "/elsewhere/.git",
                "GIT_INDEX_FILE": "/tmp/index",
                "GIT_SSL_CAINFO": "/etc/corp.pem",
                "HOME": "/Users/me",
                "LANG": "ja_JP.UTF-8"
            ],
            given: ["GIT_TERMINAL_PROMPT": "0", "GIT_INDEX_FILE": "/tmp/copy"]
        )
        #expect(env == [
            "GIT_SSL_CAINFO": "/etc/corp.pem",
            "HOME": "/Users/me",
            "LANG": "C",
            "LC_ALL": "C",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_INDEX_FILE": "/tmp/copy"
        ])
    }
}

/// Which git Weir runs, from the `PATH` it was opened with.
struct GitExecutableLocateTests {
    /// Folders `name`d under `root`, each holding an executable `git`.
    private func gitFolders(_ names: [String], in root: URL) throws -> [String] {
        try names.map { name in
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let git = folder.appendingPathComponent("git")
            try "#!/bin/sh\n".write(to: git, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: git.path)
            return folder.path
        }
    }

    /// Opened from the Dock, the app has launchd's `PATH`: a git in a
    /// well-known install folder wins over the one in `/usr/bin`.
    @Test func withLaunchdsPath_aWellKnownFolderWins() throws {
        try withTempDir { root in
            let folders = try gitFolders(["homebrew"], in: root)
            let found = GitExecutable.locate(inheritedPath: "/usr/bin:/bin:/usr/sbin:/sbin", wellKnownDirectories: folders)
            #expect(found.path == folders[0] + "/git")
        }
    }

    /// Opened from a terminal, the app has that terminal's `PATH`, and its
    /// order wins.
    @Test func withATerminalsPath_itsOrderWins() throws {
        try withTempDir { root in
            let folders = try gitFolders(["chosen", "homebrew"], in: root)
            let found = GitExecutable.locate(inheritedPath: folders[0] + ":/usr/bin", wellKnownDirectories: [folders[1]])
            #expect(found.path == folders[0] + "/git")
        }
    }

    @Test func withNoGitAnywhere_itIsTheSystemsGit() throws {
        try withTempDir { root in
            let found = GitExecutable.locate(inheritedPath: root.path, wellKnownDirectories: [])
            #expect(found.path == "/usr/bin/git")
        }
    }
}
