// IgnoredFilesDraftTests.swift
// Weir — Project Settings' list of the files to copy into new worktrees: what is saved, what is marked, and the ignored files' menu.

import Foundation
import Testing
@testable import Weir

struct IgnoredFilesDraftTests {
    @Test func theRows_saveWhatCanBeUsed_andMarkTheRest() throws {
        var draft = IgnoredFilesDraft(patterns: [".env"])
        let original = try #require(draft.rows.first)
        let empty = draft.add()
        let copy = draft.add("./.env")
        let outside = draft.add("../secret")
        let git = draft.add(".git/config")
        #expect(draft.problem(of: empty, editing: empty) == nil, "a row being typed in is not marked")
        #expect(draft.problem(of: empty) == .empty)
        #expect(draft.problem(of: copy) == .duplicate)
        #expect(draft.problem(of: outside) == .unsafe(.leavesFolder))
        #expect(draft.problem(of: git) == .unsafe(.namesGitFolder))
        #expect(draft.patterns == [".env"])
        #expect(draft.problem(of: original.id) == nil)
        #expect(draft.rows.map(\.id) == [original.id, empty, copy, outside, git])
        #expect(draft.rows.map(\.text) == [".env", "", "./.env", "../secret", ".git/config"])
    }

    @Test func anEmptyList_savesNil_asAProjectThatNamedNone() throws {
        let original = IgnoredFilesDraft(patterns: [".env"])
        var draft = original
        try draft.remove(#require(draft.rows.first).id)
        #expect(draft.rows.isEmpty)
        #expect(IgnoredFilesDraft.save(from: original, to: draft) == .patterns(nil))
        #expect(draft.patterns == nil)
        #expect(IgnoredFilesDraft(patterns: nil).rows.isEmpty)
    }

    /// The draft emits a save decision only when its usable patterns change.
    @Test func onlyAnEditThatChangesUsablePatterns_requestsSaving() {
        let opened = IgnoredFilesDraft(patterns: [".env"])
        var edited = opened
        let added = edited.add()
        #expect(IgnoredFilesDraft.save(from: opened, to: edited) == .nothing)
        edited.setText("config/master.key", of: added)
        #expect(IgnoredFilesDraft.save(from: opened, to: edited) == .patterns([".env", "config/master.key"]))
    }

    @Test func theIgnoredFilesMenu_addsAndRemovesTheRowNamingAPath() {
        var draft = IgnoredFilesDraft(patterns: nil)
        draft.toggle("node_modules/")
        #expect(draft.contains("node_modules/"))
        #expect(draft.patterns == ["/node_modules/"], "anchored: that one folder, no other of its name")
        draft.add(" /node_modules/ ")
        let unrelated = draft.add(".env")
        draft.toggle("node_modules/")
        #expect(!draft.contains("node_modules/"))
        #expect(draft.rows.map(\.id) == [unrelated])
        #expect(draft.patterns == [".env"])
    }
}
