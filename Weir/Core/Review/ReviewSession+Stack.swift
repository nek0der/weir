// ReviewSession+Stack.swift
// Weir — the session's side of the review tab's stacked diff: which files to read, and what each read changes.

import Foundation

extension ReviewSession {
    /// The files on screen and a screen either side: read the ones not read
    /// yet, and keep them all while the reader is there.
    func loadStacked(window fileIDs: [String]) {
        let window = Set(fileIDs)
        // Asked on every scroll event, so the common answer, nothing new, is
        // found before the list is looked at.
        guard window != stackLoader.window || window.contains(where: stackLoader.needsDiff) else { return }
        let requests = files
            .filter { window.contains($0.id) && stackLoader.needsDiff($0.id) }
            .map { ReviewStackLoader.Request(file: $0, scope: scopeForFile($0)) }
        stackLoader.request(requests, window: window)
    }

    /// Requests the rest of the range for Find, as far as the measured budget
    /// allows. Files whose exact counts exceed the per-file limit are skipped.
    @discardableResult
    func loadStackForSearch(_ files: [ReviewFile]) -> Task<Void, Never> {
        let listRead = listReadCount
        let ticket = stackLoader.beginSearch()
        let unreadable = Set(files.filter { isTooLargeForSearch($0) }.map(\.id))
        let requests = files.filter { !unreadable.contains($0.id) }
            .map { ReviewStackLoader.Request(file: $0, scope: scopeForFile($0)) }
        return Task {
            guard listReadCount == listRead else { return }
            stackLoader.requestAll(requests, ticket: ticket, isPartial: !unreadable.isEmpty)
        }
    }

    private func isTooLargeForSearch(_ file: ReviewFile) -> Bool {
        guard let stat = stats[file.id], !stat.isBinary else { return false }
        switch file.status {
        case .added, .deleted:
            // The patch shows the whole file and at least two metadata rows.
            return stat.added + stat.removed + 2 > ReviewDiffParser.maxRows
        case .untracked:
            return stat.added > ReviewDiffParser.maxRows
        default:
            return false
        }
    }

    /// Keeps the open file's diff in the stack, so the file draws the same
    /// rows when another is opened.
    func rememberInStack(_ diff: ReviewDiff, read: StackRead) {
        stackLoader.remember(diff, state: read.state, serial: read.serial, scope: scopeForFile(diff.file))
    }

    /// A read of the open file, as the stack numbers and records its own.
    struct StackRead {
        let serial: Int
        let state: ReviewReadState?
    }

    /// Starts a read of the open file for the stack: its number, and what
    /// the file is just before it (nothing for a fixed range of turns, which
    /// cannot change). `nil` with no file to read.
    func beginStackRead(_ file: ReviewFile?, scope: ReviewScope) async -> StackRead? {
        guard let file else { return nil }
        if case .turns = scope {
            return StackRead(serial: stackLoader.beginRead(), state: nil)
        }
        let state = await stackLoader.takeState(of: file, scope: scope)
        // Numbered after its state, as the stack's own reads are: the read
        // itself comes next.
        return StackRead(serial: stackLoader.beginRead(), state: state)
    }

    /// Each file the stack read is checked as the open file is: a comment
    /// written against another version of it is stale, and a read mark on
    /// code that has since changed comes off.
    func reconcileStacked(_ diffs: [ReviewDiff]) {
        let listed = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Not the open file: what is displayed of it is its own diff, which
        // a background read can be another version of.
        for diff in diffs where diff.file.id != self.diff?.file.id {
            guard let file = listed[diff.file.id] else { continue }
            reconcileLoadedDiff(diff, for: file)
        }
    }
}
