// WorktreePathResolverTests.swift
// Weir — a worktree path is resolved through its links once, and let go of with its project.

import Foundation
import Testing
@testable import Weir

@MainActor
struct WorktreePathResolverTests {
    @Test func aLinkedFolder_resolvesToItsTarget() throws {
        try withTempDir { dir in
            let real = dir.appendingPathComponent("real")
            let link = dir.appendingPathComponent("link")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let paths = WorktreePathResolver()

            #expect(paths.resolved(link.path) == real.resolvingSymlinksInPath().path)
            #expect(paths.resolved(link.path) == paths.resolved(real.path), "both spellings are one worktree's records")
            let isRoot = paths.isRoot(real.path)
            #expect(isRoot(link.path))
            #expect(isRoot(real.path))
            #expect(!isRoot(real.appendingPathComponent("child").path))
        }
    }

    @Test func forgettingAProject_resolvesItsDescendantsAgain_andKeepsOtherProjectsCached() {
        var resolutions: [String] = []
        var linkTarget = "/projects/one/worktree"
        let paths = WorktreePathResolver { path in
            resolutions.append(path)
            return path == "/link" ? linkTarget : path
        }

        #expect(paths.resolved("/link") == "/projects/one/worktree")
        #expect(paths.resolved("/link") == "/projects/one/worktree")
        #expect(paths.resolved("/projects/one") == "/projects/one")
        #expect(paths.resolved("/projects/one-other/worktree") == "/projects/one-other/worktree")
        #expect(resolutions == ["/link", "/projects/one", "/projects/one-other/worktree"])

        paths.forget([])
        #expect(paths.generation == 0)
        paths.forget(["/projects/one"])
        #expect(paths.generation == 1)
        linkTarget = "/projects/elsewhere/worktree"

        #expect(paths.resolved("/link") == "/projects/elsewhere/worktree")
        #expect(paths.resolved("/projects/one") == "/projects/one")
        #expect(paths.resolved("/projects/one-other/worktree") == "/projects/one-other/worktree")
        #expect(resolutions == ["/link", "/projects/one", "/projects/one-other/worktree", "/link", "/projects/one"])
    }
}
