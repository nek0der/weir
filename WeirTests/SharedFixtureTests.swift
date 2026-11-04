// SharedFixtureTests.swift
// Weir — checks that the shared test fixtures keep the behavior each suite's own copy used to give it.

import Foundation
import Testing
@testable import Weir

struct SharedFixtureTests {

    // MARK: - TestProcess

    @Test func process_handsOnStdin_startsInCwd_andAnswersTheStatus() throws {
        try withTempDir { dir in
            let output = try TestProcess.run(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "cat; pwd >&2; exit 3"],
                stdin: Data("given".utf8),
                cwd: dir
            )
            #expect(output.ending == .exited)
            #expect(output.status == 3)
            #expect(output.stdoutText == "given")
            let cwd = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == dir.resolvingSymlinksInPath())
        }
    }

    /// More stdin than a pipe holds, to a child that writes all of it back:
    /// the stdin is a file, so nothing of ours waits on the child reading it
    /// while the child waits on us to read its stdout.
    @Test func process_aPayloadPastThePipesBuffer_doesNotHang() throws {
        let payload = Data(repeating: UInt8(ascii: "x"), count: 1 << 20)
        let output = try TestProcess.run(URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: payload)
        #expect(output.ending == .exited)
        #expect(output.stdout == payload)
    }

    /// A child that exits without reading its stdin ends the run at once.
    @Test func process_aChildThatExitsWithoutReading_endsTheRunAtOnce() throws {
        let payload = Data(repeating: UInt8(ascii: "x"), count: 1 << 20)
        let started = ContinuousClock.now
        let output = try TestProcess.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [], stdin: payload)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(output.ending == .exited)
        #expect(output.status == 0)
    }

    /// A child that stays alive and never reads is ended at the deadline.
    @Test func process_aChildThatNeverReads_isEndedAtTheDeadline() throws {
        let payload = Data(repeating: UInt8(ascii: "x"), count: 1 << 20)
        let started = ContinuousClock.now
        let output = try TestProcess.run(
            URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            stdin: payload,
            timeout: .seconds(1)
        )
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(output.ending == .timedOut)
    }

    /// Something the child started keeps its stdin open past the child's exit
    /// without reading it, and the run still ends with the child.
    @Test func process_aDescendantHoldingStdin_doesNotHoldTheRun() throws {
        let payload = Data(repeating: UInt8(ascii: "x"), count: 1 << 20)
        let started = ContinuousClock.now
        let output = try TestProcess.run(
            URL(fileURLWithPath: "/bin/sh"),
            // Stdin redirected explicitly: a background job of a shell without
            // job control otherwise reads /dev/null.
            arguments: ["-c", "sleep 8 0<&0 >/dev/null 2>&1 & exit 0"],
            stdin: payload
        )
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(output.ending == .exited)
    }

    // MARK: - Temporary folders

    /// A socket named like the ones the suites make fits in `sun_path`'s 104
    /// bytes, the folder is the owner's alone, and it is gone once the body throws.
    @Test func shortTempDir_holdsASocketPath_andIsGoneAfterAThrow() throws {
        struct Planned: Error {}
        var made: URL?
        #expect(throws: Planned.self) {
            try withShortTempDir { dir in
                made = dir
                #expect(dir.appendingPathComponent("default").path.utf8.count < 104)
                let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
                #expect(mode?.intValue == 0o700)
                throw Planned()
            }
        }
        let folder = try #require(made)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func scratchFile_writesThroughFoldersThatAreNotThereYet() throws {
        try withTempDir { dir in
            try ScratchFile.write("deep", to: "a/b/c.txt", in: dir)
            #expect(try ScratchFile.read("a/b/c.txt", in: dir) == "deep")
            #expect(throws: (any Error).self) { try ScratchFile.read("missing.txt", in: dir) }
        }
    }

    // MARK: - TempGitRepo

    @Test(.tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func tempGitRepo_commitsWhatItWrote_andThrowsOnAFailedCommand() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try repo.write("one\n", to: "dir/a.txt")
        try await repo.commit("first", paths: ["dir/a.txt"])
        #expect(try await repo.git(["log", "-1", "--format=%s"]) == "first")
        #expect(try await repo.git(["status", "--porcelain"]).isEmpty)
        #expect(try repo.read("dir/a.txt") == "one\n")
        await #expect(throws: TempGitRepo.GitFailure.self) { try await repo.git(["checkout", "-q", "no-such-branch"]) }
    }

    // MARK: - ShimHarness

    @Test func recordingStub_recordsItsArgumentsItsStartAndItsEnvironment() throws {
        try withTempDir { dir in
            let stub = try ShimHarness.recordingStub(named: "agent", in: dir)
            let output = try TestProcess.run(
                stub,
                arguments: ["one", "two words", ""],
                environment: ShimHarness.environment(in: dir, merging: ["MARK": "set", "PATH": "/usr/bin:/bin"])
            )
            #expect(output.status == 0)
            #expect(
                ShimHarness.recordedArgv(ShimHarness.argvRecord(in: dir), keepsEmptyArguments: true)
                    == ["one", "two words", ""]
            )
            #expect(ShimHarness.launched(in: dir) == [stub.path, "/usr/bin:/bin"])
            let environment = try ScratchFile.read("env", in: dir).split(separator: "\n")
            #expect(environment.contains("MARK=set"))
            #expect(environment.contains("HOME=\(dir.path)"))
        }
    }

    @Test func shimEnvironment_letsWhatItIsGivenWin() {
        let dir = URL(fileURLWithPath: "/scratch")
        let environment = ShimHarness.environment(in: dir, merging: ["HOME": "/scratch/home"])
        #expect(environment["HOME"] == "/scratch/home")
        #expect(environment["TMPDIR"] == "/scratch")
        #expect(environment["PATH"] == ShimHarness.systemPath)
    }

    // MARK: - Polling and JSON

    @Test func pollUntil_anAsyncCondition_returnsOnceItHolds() async {
        let counter = Counter()
        await pollUntil(timeout: .seconds(5)) { await counter.next() >= 3 }
        #expect(await counter.value == 3)
    }

    @Test func jsonObject_readsAnEncodedValuesKeys() throws {
        struct Value: Encodable {
            let name = "kept"
        }
        #expect(try JSONObjectFixture.object(encoding: Value())["name"] as? String == "kept")
        #expect(try JSONObjectFixture.object(Data(#"{"a":1}"#.utf8))["a"] as? Int == 1)
    }
}

private actor Counter {
    private(set) var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}
