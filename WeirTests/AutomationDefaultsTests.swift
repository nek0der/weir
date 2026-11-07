// AutomationDefaultsTests.swift
// Weir — a channel run in a fresh home starts with empty user defaults, and keeps them after.

#if DEBUG && WEIR_AUTOMATION

    import Foundation
    import Testing
    @testable import Weir

    @MainActor
    struct AutomationDefaultsTests {
        private let bundleID = "com.nekoder.Weir.automation-1234abcd.dev"

        /// A home removed and made again at the same path has the same
        /// identifier, whose domain still holds what the run before it set.
        @Test func aFreshHome_emptiesTheDomainBeforeTheRunReadsIt() throws {
            try withTempDir { home in
                let defaults = try #require(InMemoryDefaults())
                defaults.set("japanese", forKey: "appLanguage")

                let emptied = AutomationDefaults.startOver(dataFolder: home, bundleID: bundleID, defaults: defaults)

                #expect(emptied)
                #expect(defaults.removedDomains == [bundleID])
                #expect(defaults.string(forKey: "appLanguage") == nil)
                #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(AutomationDefaults.markName).path))
            }
        }

        /// The next run in the same home keeps what this one set.
        @Test func aHomeAlreadyMarked_keepsItsDefaults() throws {
            try withTempDir { home in
                let defaults = try #require(InMemoryDefaults())
                try #require(AutomationDefaults.startOver(dataFolder: home, bundleID: bundleID, defaults: defaults))
                defaults.set("english", forKey: "appLanguage")

                let emptied = AutomationDefaults.startOver(dataFolder: home, bundleID: bundleID, defaults: defaults)

                #expect(!emptied)
                #expect(defaults.removedDomains == [bundleID])
                #expect(defaults.string(forKey: "appLanguage") == "english")
            }
        }
    }

#endif
