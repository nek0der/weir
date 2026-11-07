// GitStatusParserTests.swift
// Weir — Swift Testing coverage for the `GitStatus` porcelain v2 parser.

import Testing
@testable import Weir

@Suite("GitStatus parser")
struct GitStatusParserTests {

    /// Exercises `parse` over hand-crafted porcelain v2 fragments — no IO.
    @Test(
        "parses the branch and counts the changed entries",
        arguments: [
            // Each fragment has a complete, independent expected status.
            (
                """
                # branch.oid abc
                # branch.head main
                # branch.upstream origin/main
                # branch.ab +0 -0
                """,
                GitWorktreeStatus(branch: "main", upstream: "origin/main", changedEntries: 0, hasAheadBehind: true)
            ),
            (
                """
                # branch.oid bbb
                # branch.head dev
                1 .M N... 100644 100644 100644 aaa bbb file.swift
                """,
                GitWorktreeStatus(branch: "dev", changedEntries: 1)
            ),
            (
                """
                # branch.oid aaa
                # branch.head main
                ? newfile.txt
                """,
                GitWorktreeStatus(branch: "main", changedEntries: 1)
            ),
            ("# branch.oid aaa\n# branch.head (detached)", GitWorktreeStatus()),
            ("", GitWorktreeStatus())
        ]
    )
    func parse_porcelainV2_extractsBranchAndStatus(
        porcelain: String,
        expected: GitWorktreeStatus
    ) {
        #expect(GitStatus.parse(porcelain) == expected)
    }

    @Test func parse_countsEachChangedRenamedUnmergedAndUntrackedEntry_butNotIgnoredOnes() {
        let porcelain = """
        # branch.oid aaa
        # branch.head main
        1 .M N... 100644 100644 100644 aaa bbb changed.swift
        2 R. N... 100644 100644 100644 aaa bbb R100 new.swift\told.swift
        u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.swift
        ? untracked.txt
        ! ignored.log
        """
        let records = [
            ("1 .M N... 100644 100644 100644 aaa bbb changed.swift", 1),
            ("2 R. N... 100644 100644 100644 aaa bbb R100 new.swift\told.swift", 1),
            ("u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.swift", 1),
            ("? untracked.txt", 1),
            ("! ignored.log", 0)
        ]
        for (record, expected) in records {
            #expect(GitStatus.parse(record).changedEntries == expected, "\(record)")
        }
        #expect(GitStatus.parse(porcelain).changedEntries == 4)
        #expect(GitStatus.parse("# branch.oid aaa\n# branch.head main").changedEntries == 0)
    }

    @Test func parse_tellsAnUpstreamWithCountsFromOneGoneFromTheRemote() {
        let tracked = GitStatus.parse("""
        # branch.head feat
        # branch.upstream origin/feat
        # branch.ab +2 -0
        """)
        #expect(tracked.hasAheadBehind)

        // Git reports the upstream but no counts once its branch is gone.
        let gone = GitStatus.parse("""
        # branch.head feat
        # branch.upstream origin/feat
        """)
        #expect(gone.upstream == "origin/feat")
        #expect(!gone.hasAheadBehind)
    }

}
