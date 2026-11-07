// NewSessionSettingsTests.swift
// Weir — what the new worktree sheet remembers of each project, what an earlier build kept, and how a file it cannot read is kept.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite(.tags(.persistence))
struct NewSessionSettingsTests {
    private static let app = URL(fileURLWithPath: "/tmp/work/app")

    @Test func theSheet_remembersWhatOpened_theFetch_andEachProjectsBoxes() throws {
        var settings = NewSessionSettings()
        settings.fetchesBeforeCreate = false
        let other = URL(fileURLWithPath: "/tmp/work/other")
        settings.remember(
            NewWorktreeChoices(open: .agent(.codex), fetches: true, copiesIgnoredFiles: false, runsSetup: true),
            forProjectAt: Self.app
        )
        #expect(settings.lastOpen == "codex")
        #expect(settings.fetchesBeforeCreate)
        settings.remember(NewWorktreeChoices(open: .shell, fetches: false, copiesIgnoredFiles: true, runsSetup: false), forProjectAt: other)
        #expect(settings.memory(forProjectAt: Self.app) == NewWorktreeProjectMemory(
            open: "codex",
            copiesIgnoredFiles: false,
            runsSetup: true
        ))
        #expect(settings.memory(forProjectAt: other) == NewWorktreeProjectMemory(
            open: "shell",
            copiesIgnoredFiles: true,
            runsSetup: false
        ))
        // What opened last anywhere, and the fetch, are the last remembered.
        #expect(settings.lastOpen == "shell")
        #expect(!settings.fetchesBeforeCreate)
        // The same folder by another spelling is the same project.
        #expect(settings.memory(forProjectAt: URL(fileURLWithPath: "/tmp/work/./app")) == NewWorktreeProjectMemory(
            open: "codex", copiesIgnoredFiles: false, runsSetup: true
        ))
        #expect(settings.memory(forProjectAt: URL(fileURLWithPath: "/tmp/work/new")) == nil)

        var decoded = WeirSettings.default
        decoded.newSession = settings
        let roundTripped = try JSONDecoder().decode(WeirSettings.self, from: JSONEncoder().encode(decoded))
        #expect(roundTripped.newSession == settings)
    }

    /// The fetch is on until turned off, and a file that never turned it
    /// off does not gain the key.
    @Test func theFetch_isOnByDefault_andWrittenOnlyOnceOff() throws {
        let fresh = try JSONObjectFixture.object(encoding: WeirSettings.default)
        #expect((fresh["newSession"] as? [String: Any])?["fetchesBeforeCreate"] == nil)
        #expect(WeirSettings.default.newSession.fetchesBeforeCreate)
        let missing = try JSONDecoder().decode(NewSessionSettings.self, from: Data(#"{"lastOpen":"shell"}"#.utf8))
        #expect(missing.lastOpen == "shell")
        #expect(missing.fetchesBeforeCreate)
        var off = WeirSettings.default
        off.newSession.fetchesBeforeCreate = false
        let written = try JSONObjectFixture.object(encoding: off)
        #expect((written["newSession"] as? [String: Any])?["fetchesBeforeCreate"] as? Bool == false)
        var reloaded = try WeirSettingsJSON.decode(written)
        #expect(!reloaded.newSession.fetchesBeforeCreate)
        reloaded.newSession.fetchesBeforeCreate = true
        let restored = try JSONObjectFixture.object(encoding: reloaded)
        let restoredSession = try #require(restored["newSession"] as? [String: Any])
        #expect(!restoredSession.keys.contains("fetchesBeforeCreate"))
        #expect(try WeirSettingsJSON.decode(restored).newSession.fetchesBeforeCreate)
    }

    /// What an earlier build kept (the agent and the location) is read to
    /// start from, and written back untouched, so going back a build finds
    /// it as it left it.
    @Test func anEarlierBuildsAgentAndLocation_areKept_asTheyWereWritten() throws {
        var object = try JSONObjectFixture.object(encoding: WeirSettings.default)
        object["newSession"] = ["lastAgent": "codex", "projects": ["/tmp/work/app": ["agent": "claude", "location": "projectFolder"]]]
        var settings = try WeirSettingsJSON.decode(object)
        #expect(settings.newSession.rememberedOpen(forProjectAt: Self.app) == [nil, nil, "claude", "codex"])
        settings.newSession.remember(
            NewWorktreeChoices(open: .nothing, fetches: true, copiesIgnoredFiles: true, runsSetup: true),
            forProjectAt: Self.app
        )
        #expect(settings.newSession.rememberedOpen(forProjectAt: Self.app) == ["nothing", "nothing", "claude", "codex"])
        let written = try JSONObjectFixture.object(encoding: settings)
        let newSession = written["newSession"] as? [String: Any]
        #expect(newSession?["lastAgent"] as? String == "codex")
        let project = (newSession?["projects"] as? [String: Any])?["/tmp/work/app"] as? [String: Any]
        #expect(project?["agent"] as? String == "claude")
        #expect(project?["location"] as? String == "projectFolder")
        #expect(project?["open"] as? String == "nothing")
    }

    @Test func aProjectsChoicesThatDoNotRead_dropOnlyThemselves() throws {
        var object = try JSONObjectFixture.object(encoding: WeirSettings.default)
        object["newSession"] = [
            "lastOpen": "codex",
            "projects": [
                "/tmp/bad": "not an object",
                "/tmp/wrong": ["open": 3],
                "/tmp/good": ["open": "shell", "runsSetup": false]
            ]
        ]
        let settings = try WeirSettingsJSON.decode(object)
        #expect(settings.newSession.lastOpen == "codex")
        #expect(settings.newSession.projects == ["/tmp/good": NewWorktreeProjectMemory(open: "shell", runsSetup: false)])
    }

    @Test func aLaterBuildsChoiceAndFields_surviveReadingAndEditingKnownValues() throws {
        let root = URL(fileURLWithPath: "/tmp/app")
        let bytes = Data(#"""
        {
          "lastOpen": "gemini",
          "laterTop": true,
          "projects": {"/tmp/app": {"open": "gemini", "laterKey": 1}}
        }
        """#.utf8)
        var later = try JSONDecoder().decode(NewSessionSettings.self, from: bytes)
        #expect(later.lastOpen == "gemini")
        #expect(later.memory(forProjectAt: root)?.open == "gemini")
        #expect(WorktreeOpenChoice.initial(remembered: later.rememberedOpen(forProjectAt: root), installed: [.claude]) == .agent(.claude))

        let unchanged = try JSONObjectFixture.object(encoding: later)
        #expect(unchanged["lastOpen"] as? String == "gemini")
        let unchangedProjects = try #require(unchanged["projects"] as? [String: [String: Any]])
        #expect(unchangedProjects["/tmp/app"]?["open"] as? String == "gemini")
        #expect(unchangedProjects["/tmp/app"]?["laterKey"] as? Int == 1)
        #expect(unchanged["laterTop"] as? Bool == true)

        later.remember(NewWorktreeChoices(open: .shell, fetches: false, copiesIgnoredFiles: false, runsSetup: true), forProjectAt: root)
        let written = try JSONObjectFixture.object(encoding: later)
        #expect(written["laterTop"] as? Bool == true)
        #expect(written["lastOpen"] as? String == "shell")
        #expect(written["fetchesBeforeCreate"] as? Bool == false)
        let projects = try #require(written["projects"] as? [String: [String: Any]])
        let edited = try #require(projects["/tmp/app"])
        #expect(edited["laterKey"] as? Int == 1)
        #expect(edited["open"] as? String == "shell")
        #expect(edited["copiesIgnoredFiles"] as? Bool == false)
        #expect(edited["runsSetup"] as? Bool == true)
    }
}
