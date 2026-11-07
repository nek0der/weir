// AgentFileLockTests.swift
// Weir — the record lock taken on the sidecar at the path, not one a sweep removed.

import Darwin
import Foundation
import Testing
@testable import Weir

@Suite("Agent file lock")
struct AgentFileLockTests {
    @Test func aSidecarReplacedAtThePath_isNotTheOneStillOpen() throws {
        try withTempDir { directory in
            let sidecar = directory.appendingPathComponent("run.json.flock").path
            let stale = open(sidecar, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            try #require(stale >= 0)
            defer { close(stale) }
            #expect(AgentFileLock.isAtPath(stale, sidecar))

            // What a sweep does to a sidecar whose file is gone, and what the
            // next writer's open does after it.
            try #require(unlink(sidecar) == 0)
            #expect(!AgentFileLock.isAtPath(stale, sidecar))
            let next = open(sidecar, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            try #require(next >= 0)
            defer { close(next) }

            #expect(!AgentFileLock.isAtPath(stale, sidecar))
            #expect(AgentFileLock.isAtPath(next, sidecar))
        }
    }
}
