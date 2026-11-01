// DemoFixture+Review.swift
// Weir — what the demo's review reads: the selected worktree's five uncommitted files and one saved comment.

import Foundation

extension DemoFixture {
    /// The uncommitted files the fixture names (`gitFacts`, `remindersScreen`)
    /// and their counts, which sum to `worktreeCounts`. Only `reviewedFile`
    /// has its whole patch: the capture crops to it, and the others are short
    /// stand-ins below it.
    static let stagedReviewFiles: [(file: ReviewFile, stat: ReviewFileStat)] = [
        (changed("apps/api/src/reminders/selectOverdue.ts"), ReviewFileStat(added: 31, removed: 4)),
        (changed("apps/web/src/billing/BillingPage.tsx"), ReviewFileStat(added: 6, removed: 9)),
        (untracked("apps/api/migrations/20261020_reminder_schedules.sql"), ReviewFileStat(added: 24, removed: 0)),
        (untracked("apps/api/src/reminders/selectOverdue.test.ts"), ReviewFileStat(added: 58, removed: 0)),
        (untracked("apps/web/src/billing/ReminderSettings.tsx"), ReviewFileStat(added: 41, removed: 0))
    ]

    static var reviewedFile: ReviewFile {
        stagedReviewFiles[0].file
    }

    private static func changed(_ path: String) -> ReviewFile {
        ReviewFile(path: path, layer: .unstaged, status: .modified)
    }

    private static func untracked(_ path: String) -> ReviewFile {
        ReviewFile(path: path, layer: .untracked, status: .untracked)
    }

    fileprivate static func fingerprint(of file: ReviewFile) -> String {
        "demo:" + file.id
    }

    fileprivate static func patch(of file: ReviewFile) -> String {
        file == reviewedFile ? reviewedPatch : """
        diff --git a/\(file.path) b/\(file.path)
        --- a/\(file.path)
        +++ b/\(file.path)
        @@ -0,0 +1 @@
        +// \(file.path)

        """
    }

    /// +31 −4, as the turn that made it says.
    private static let reviewedPatch = """
    diff --git a/apps/api/src/reminders/selectOverdue.ts b/apps/api/src/reminders/selectOverdue.ts
    --- a/apps/api/src/reminders/selectOverdue.ts
    +++ b/apps/api/src/reminders/selectOverdue.ts
    @@ -12,10 +12,37 @@ import type { Invoice } from "../invoices/types";
     const GRACE_DAYS = 3;
    \u{20}
     export async function selectOverdue(db: Db, now: Date): Promise<Invoice[]> {
    -  const invoices = await db.invoices.findMany({
    -    where: { dueAt: { lt: daysBefore(now, GRACE_DAYS) } },
    -  });
    -  return invoices;
    +  const invoices = await db.invoices.findMany({
    +    where: {
    +      status: "open",
    +      dueAt: { lt: daysBefore(now, GRACE_DAYS) },
    +    },
    +    include: { payments: true, disputes: true },
    +  });
    +
    +  return invoices.filter((invoice) => isStillOwed(invoice, now));
    +}
    +
    +// A payment can arrive after the job starts, so we read what is left to
    +// pay rather than trust the invoice's status alone.
    +function isStillOwed(invoice: InvoiceWithHistory, now: Date): boolean {
    +  if (invoice.disputes.some((dispute) => dispute.openedAt <= now)) {
    +    return false;
    +  }
    +
    +  const paid = invoice.payments
    +    .filter((payment) => payment.receivedAt <= now)
    +    .reduce((sum, payment) => sum + payment.amountCents, 0);
    +
    +  return invoice.totalCents - paid > 0;
    +}
    +
    +function daysSinceDue(invoice: Invoice, now: Date): number {
    +  return Math.floor((now.getTime() - invoice.dueAt.getTime()) / MS_PER_DAY);
    +}
    +
    +export function isReminderDue(invoice: Invoice, now: Date): boolean {
    +  return daysSinceDue(invoice, now) >= GRACE_DAYS;
     }
    \u{20}
     export const REMINDER_BATCH_SIZE = 200;

    """

    /// What the review holds when it opens: one comment on a line the
    /// capture shows, in the file it opens on.
    static var stagedReviewDraft: ReviewDraft {
        var draft = ReviewDraft()
        draft.lastFileID[ReviewScope.uncommitted.scopeID] = reviewedFile.id
        // Empty only if the patch stops parsing, which `DemoFixtureTests` catches.
        let lines = (try? ReviewDiffParser.parse(reviewedPatch)) ?? []
        guard let line = lines.first(where: { $0.text.contains("include: { payments: true") }) else { return draft }
        draft.comments = [ReviewComment(
            scopeIDs: [ReviewScope.uncommitted.scopeID],
            file: reviewedFile,
            fingerprint: fingerprint(of: reviewedFile),
            anchor: ReviewAnchor(lineID: line.id, oldLine: line.oldLine, newLine: line.newLine),
            code: line.text,
            codeMarkers: String(line.kind.marker),
            body: "Refunds are not loaded here. Should a refunded payment still count as paid?"
        )]
        return draft
    }
}

/// The review's answers in demo mode, whose folders do not exist. Nothing
/// moves, so every answer is the same each time it is asked.
struct DemoReviewRepository: ReviewRepositoryReading {
    func files(at _: URL, scope _: ReviewScope) async throws -> [ReviewFile] {
        DemoFixture.stagedReviewFiles.map(\.file)
    }

    func stats(at _: URL, scope _: ReviewScope) async throws -> [String: ReviewFileStat] {
        Dictionary(uniqueKeysWithValues: DemoFixture.stagedReviewFiles.map { ($0.file.id, $0.stat) })
    }

    func diff(_ file: ReviewFile, root _: URL, scope _: ReviewScope) async throws -> ReviewDiff {
        try ReviewDiff(
            file: file,
            fingerprint: DemoFixture.fingerprint(of: file),
            lines: ReviewDiffParser.parse(DemoFixture.patch(of: file))
        )
    }

    func fingerprint(_ file: ReviewFile, root _: URL, scope _: ReviewScope) async throws -> String {
        DemoFixture.fingerprint(of: file)
    }

    func indexState(root _: URL, scope _: ReviewScope, paths _: Set<String>) async throws -> ReviewIndexState {
        ReviewIndexState(head: "demo", base: nil, entries: [:])
    }

    func fileStats(_ paths: [String], root _: URL) -> [String: ReviewPathStat] {
        Dictionary(uniqueKeysWithValues: paths.map { ($0, ReviewPathStat(kind: .regular, info: "demo", size: 0)) })
    }

    func contentHashes(_ paths: [String], root _: URL) async throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: paths.map { ($0, "demo") })
    }

    func hasChanges(
        at _: URL,
        scope _: ReviewScope,
        comparedTo _: [ReviewFile],
        currentDiff _: ReviewDiff?
    ) async throws -> Bool {
        false
    }

    func source(_: ReviewFile, root _: URL, scope _: ReviewScope) async -> [String] {
        []
    }

    func defaultBase(at _: URL) async throws -> String? {
        "origin/main"
    }

    /// Each folder is its own top level, as `RepositoryRoots.staged` has it.
    func root(at directory: URL) async throws -> URL {
        directory
    }
}

/// The demo's drafts: the staged comment on the worktree the window shows,
/// and nothing kept, as `EphemeralReviewDraftStore` keeps nothing.
struct DemoReviewDraftStore: ReviewDraftStoring {
    func load(root: URL) throws -> ReviewDraft? {
        root.path == DemoFixture.selectedWorktreeRoot.path ? DemoFixture.stagedReviewDraft : nil
    }

    func save(_: ReviewDraft, root _: URL) throws {}
}
