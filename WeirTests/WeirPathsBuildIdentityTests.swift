// WeirPathsBuildIdentityTests.swift
// Weir — the identity that keeps one build's hook links apart from another
// build's: the Release app keeps its bundle id, and Debug builds in two
// worktrees, which share one bundle id, get two identities.

import Foundation
import Testing
@testable import Weir

@Suite("WeirPaths build identity")
struct WeirPathsBuildIdentityTests {
    private let firstWorktree = "/Users/someone/Library/Developer/Xcode/DerivedData/Weir-aaaa/Build/Products/Debug/Weir Dev.app"
    private let secondWorktree = "/Users/someone/Library/Developer/Xcode/DerivedData/Weir-bbbb/Build/Products/Debug/Weir Dev.app"

    @Test func debugBuilds_inTwoWorktrees_haveTwoIdentities() {
        let first = WeirPaths.buildIdentity(bundleID: "com.nekoder.Weir.dev", bundlePath: firstWorktree)
        let second = WeirPaths.buildIdentity(bundleID: "com.nekoder.Weir.dev", bundlePath: secondWorktree)

        #expect(first != second)
        #expect(first.hasPrefix("com.nekoder.Weir.dev-"))
        #expect(second.hasPrefix("com.nekoder.Weir.dev-"))
    }

    /// A rebuild in the same worktree keeps its identity, so its links stay
    /// where its running sessions look for them.
    @Test func debugBuild_atOnePath_keepsOneIdentity() {
        let first = WeirPaths.buildIdentity(bundleID: "com.nekoder.Weir.dev", bundlePath: firstWorktree)
        let again = WeirPaths.buildIdentity(bundleID: "com.nekoder.Weir.dev", bundlePath: firstWorktree)

        #expect(first == again)
        // SHA-256 of the path, cut to 8 hex digits, pinned so the value does
        // not depend on a per-process hash seed.
        #expect(WeirPaths.buildIdentity(bundleID: "com.nekoder.Weir.dev", bundlePath: "/a") == "com.nekoder.Weir.dev-6a50dc85")
    }

    /// The Release app keeps the link folder it always had, wherever it is
    /// installed, so sessions it started before an update keep their hooks.
    @Test func releaseBuild_isItsBundleID() {
        #expect(WeirPaths.buildIdentity(bundleID: "com.nekoder.Weir", bundlePath: "/Applications/Weir.app") == "com.nekoder.Weir")
        #expect(WeirPaths
            .buildIdentity(bundleID: "com.nekoder.Weir", bundlePath: "/Users/someone/Applications/Weir.app") == "com.nekoder.Weir")
    }

    /// The Claude shim replaces a namespace with other characters, or longer
    /// than 128, with `default`, which every build would share again.
    @Test func debugIdentity_isANamespaceTheClaudeShimKeeps() {
        let identity = WeirPaths.buildIdentity(bundleID: "com.nekoder.Weir.dev", bundlePath: firstWorktree)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

        #expect(identity.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(identity.count <= 128)
    }
}
