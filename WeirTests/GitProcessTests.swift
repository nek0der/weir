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
        defer { repository.cleanup() }
        let submodule = try await TempGitRepo.make()
        defer { submodule.cleanup() }

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
        try await TempGitRepo.configureForTests(linkedSubmodule)
        let localCommit = try await GitProcess.run(
            ["commit", "--allow-empty", "-m", "Local-only submodule commit"],
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
        try await repo.git(["branch", "develop"])
        let tip = try await repo.git(["rev-parse", "--verify", "refs/heads/develop"])
        let git = LiveGit()

        let invalid = try await git.createBranch(repoRoot: repo.url, name: "-D", startPoint: "develop")

        #expect(!invalid.succeeded)
        #expect(invalid.stderr.contains("not a valid branch name"))
        #expect(try await repo.git(["rev-parse", "--verify", "refs/heads/develop"]) == tip)
        try #require(try await git.createBranch(repoRoot: repo.url, name: "kept", startPoint: "develop").succeeded)
        #expect(try await repo.git(["rev-parse", "--verify", "refs/heads/kept"]) == tip)
    }

    /// A tag of the same name turns git's short name for the branch into
    /// `heads/v1`, and the new worktree sheet would not find `v1` among the
    /// branches, nor name it as the branch checked out.
    @Test
    func listLocalBranches_namesABranchByItsOwnName_besideATagOfTheSameName() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try await repo.git(["branch", "v1"])
        try await repo.git(["tag", "v1"])
        try await repo.git(["branch", "feat/nested"])
        let branches = try await GitProcess.listLocalBranches(repoRoot: repo.url)
        #expect(branches.contains("v1"))
        #expect(branches.contains("feat/nested"))
        #expect(!branches.contains { $0.hasPrefix("heads/") })
        try await repo.git(["checkout", "-q", "v1"])
        #expect(try await GitProcess.currentBranch(repoRoot: repo.url) == "v1")
        try await repo.git(["checkout", "-q", "--detach"])
        #expect(try await GitProcess.currentBranch(repoRoot: repo.url) == nil)
    }

    /// Before the first commit git already names the branch the repository
    /// will have, but there is nothing yet to make a worktree from.
    @Test
    func currentBranch_isNil_beforeTheFirstCommit() async throws {
        let branch: String? = try await withTempDir { directory in
            try await TempGitRepo.initialize(directory)
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
            sh -c 'trap "" TERM; echo $$ > "$1.tmp"; mv "$1.tmp" "$1"; sleep 30; :' hook '\(pidFile.path)' &
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

    @Test(arguments: [1, 60])
    func aTimeout_saysHowLongGitHad(_ seconds: Int) {
        let message = GitProcessError.timedOut(seconds: seconds).message
        let unit = seconds == 1 ? "second" : "seconds"
        #expect(message.resolved(in: Locale(identifier: "en")) == "git didn’t finish within \(seconds) \(unit).")
        #expect(message.resolved(in: Locale(identifier: "ja")) == "git が \(seconds) 秒以内に完了しませんでした。")
    }
}

@Suite("GitProcess resolveMainCheckout", .tags(.smoke))
struct GitProcessResolveMainCheckoutTests {

    enum Selection: CaseIterable {
        case nonRepository
        case mainRoot
        case mainSubdirectory
    }

    @Test(arguments: Selection.allCases)
    func resolveMainCheckout_keepsSelectionsOutsideLinkedWorktreeRoots(_ selection: Selection) async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let selected: URL
        switch selection {
        case .nonRepository:
            selected = repo.scratch.appendingPathComponent("unrelated", isDirectory: true)
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        case .mainRoot:
            selected = repo.url
        case .mainSubdirectory:
            selected = repo.url.appendingPathComponent("src", isDirectory: true)
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        }

        let resolved = await GitProcess.resolveMainCheckout(of: selected)
        #expect(resolved == selected)
    }

    @Test
    func resolveMainCheckout_promotesLinkedWorktreeRoot_toMainCheckout() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let linkedPath = try await repo.addLinkedWorktree(branch: "feature")
        let subdirectory = linkedPath.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: false)

        let resolved = await GitProcess.resolveMainCheckout(of: linkedPath)

        #expect(resolved.standardizedFileURL == repo.url.standardizedFileURL)
        #expect(await GitProcess.resolveMainCheckout(of: subdirectory) == subdirectory)
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

    /// The invocation places our fsmonitor override before the Git subcommand.
    @Test func aRun_passesFsmonitorOverride_andGivenVariables() async throws {
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

    enum SearchPath: CaseIterable {
        case launchd
        case terminal
        case noCandidate
    }

    @Test(arguments: SearchPath.allCases)
    func locate_usesTheSearchOrderForTheInheritedPath(_ searchPath: SearchPath) throws {
        try withTempDir { root in
            switch searchPath {
            case .launchd:
                let folders = try gitFolders(["homebrew"], in: root)
                let found = GitExecutable.locate(inheritedPath: "/usr/bin:/bin:/usr/sbin:/sbin", wellKnownDirectories: folders)
                #expect(found.path == folders[0] + "/git")
            case .terminal:
                let folders = try gitFolders(["homebrew", "a", "z"], in: root)
                let path = [folders[2], folders[1], "/usr/bin"].joined(separator: ":")
                let found = GitExecutable.locate(inheritedPath: path, wellKnownDirectories: [folders[0]])
                #expect(found.path == folders[2] + "/git")
            case .noCandidate:
                let found = GitExecutable.locate(inheritedPath: root.path, wellKnownDirectories: [])
                #expect(found.path == "/usr/bin/git")
            }
        }
    }
}
