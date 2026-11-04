# Documents

The index of Weir's documents, and the rules for writing and keeping them. Most
are for people who work on Weir. `user-guide.md` and `known-limitations.md` are
for people who use it, as are the repository's [`README.md`](../README.md) and
the site, built from [`site/`](../site/README.md). Each subject has one home
here, and the others link to it. [`ARCHITECTURE.md`](../ARCHITECTURE.md) is the
map of the code, [`AGENTS.md`](../AGENTS.md) holds the rules every coding agent
reads, and [`.agents/skills/`](../.agents/skills/README.md) the procedures they
follow.

## Index

| Document | What it is the home of |
| --- | --- |
| [`user-guide.md`](user-guide.md) | The app as a person uses it: each part of the window, the workflow, and the main default shortcuts. |
| [`known-limitations.md`](known-limitations.md) | What a person meets as a limit, and what has not been checked on a real machine. |
| [`provider-adapters.md`](provider-adapters.md) | The provider adapter, the capabilities that say how a provider differs, the turn rules, and what each provider needed beyond the contract. |
| [`agent-integration-protocol.md`](agent-integration-protocol.md) | The approval service's wire protocol, and how each provider's hooks map onto turn records. |
| [`data-migration.md`](data-migration.md) | Every file Weir stores, and how each one moves between versions. |
| [`verification-channel.md`](verification-channel.md) | The Debug-only channel agents use to check a running build. |
| [`libghostty-fork.md`](libghostty-fork.md) | Why we carry a libghostty fork, its patches, and how one is added or retired. |

### Decision records

| ADR | Status |
| --- | --- |
| [0001 Agent integration service](adr/0001-agent-integration-service.md) | Accepted |
| [0002 Portable agent integration core](adr/0002-portable-agent-integration-core.md) | Accepted |
| [0003 Agent integration service reconciliation](adr/0003-agent-integration-service-reconciliation.md) | Accepted |
| [0004 Provider adapter contract](adr/0004-provider-adapter-contract.md) | Accepted |
| [0005 Agent verification surface](adr/0005-agent-verification-surface.md) | Accepted |
| [0006 Keys posted to a background run](adr/0006-keys-posted-to-a-background-run.md) | Accepted |
| [0007 Unreachable service and temporary locations](adr/0007-unreachable-service-and-temporary-locations.md) | Accepted |

## Keeping them true

- A document describes the code as it is now. A pull request that changes
  what a document describes updates it in the same pull request.
- The same pull request updates this index when a document is added,
  removed, or renamed, or an ADR is added or changes status.
- Notes for one person or one task (an investigation, a checklist) do not
  go in the repository. Keep them outside the checkout.

## Decision records

An ADR under `adr/` records a decision that is hard to reverse and whose
reason the code does not show, with the alternatives it ruled out. Read the
ADRs of an area before changing its shape.

- **An ADR changes only when a decision changes.** If a pull request that
  changes no decision would have to edit an ADR, the text it would edit
  belongs in a document. How the code works today, plans, and open
  questions never go in an ADR.
- **A new decision is a new ADR**, with the next free number. Numbers are
  never reused or changed, because code comments cite them.
- **A new decision that changes part of an older one**, without reversing
  it, is a new ADR with `Amends`. The older one gets an `Amended by` line.
- **A reversed decision** is a new ADR with `Supersedes`. The older one's
  status becomes `Superseded by ADR NNNN`, and its text stays as it was.
- **A correction or an addition that leaves the decision standing** is made
  in place, with an `Amended` line in the header.
- **A withdrawn part** is replaced in place by why it was withdrawn, with an
  `Amended` line.
- **`Retired`** means that what the ADR decided about no longer exists in
  the code. The record stays, and so does its row in the index. No ADR is
  deleted.

## Format

### A document

- The title is a noun phrase in sentence case (`# Known limitations`).
- The first paragraph says what the document is the home of. Then it links
  the ADR that gives the reason, when there is one, and the documents that
  share its subject.
- It says what is true now. History goes only where a reader needs it to
  handle data an earlier build left. Plans and open questions belong in
  issues, except a short `## Not solved yet` section of what a reader would
  otherwise trip over.
- A build of Weir is named by its version (`0.1.14`), never by a word that
  a later release makes false ("this release", "the previous release").
- A fact about another program names the version it was seen on
  (`Claude Code 2.1.312`), not a date, so a reader can tell when it needs
  checking again.
- Code is named by its identifier in backticks. Another file in the
  repository is a relative link the first time a section names it.
- Sections are `##`, with `###` under them and no deeper. A section is
  referred to by its title in quotes ("Work outside a turn").
- English with US spelling, and prose wrapped at about 80 columns. Tables,
  and a line that holds only a link, are not wrapped.

### An ADR

The file is `adr/NNNN-<title-in-kebab-case>.md`.

```markdown
# ADR NNNN: Title in sentence case

- Status: Accepted.
- Date: YYYY-MM-DD.
- Amends: [ADR NNNN](NNNN-....md), by <what it changes there>.
- Amended by: [ADR NNNN](NNNN-....md), which <what it changes here>.
- Supersedes: [ADR NNNN](NNNN-....md).
- Amended: YYYY-MM-DD. <What changed.> The decision is unchanged.

## Context

What forced a decision, and the facts it rested on then.

## Decision

What we decided, one rule per bullet, each with its reason.

## Consequences

What follows from it, good and bad.

## Alternatives considered

Each option we ruled out, and why.

## References
```

- `Status` is `Accepted`, `Superseded by ADR NNNN`, or `Retired`.
- `Date` is the day the ADR was accepted, and it never changes.
- `Amends`, `Amended by`, `Supersedes`, and `Amended` lines appear only when
  they apply, and each relation is written on both ADRs.
- There is one `Amended` line per change, oldest first. Each says what
  changed, in a sentence or two. It ends by saying whether the decision
  stands ("The decision is unchanged."), so an amended ADR is safe to skim.
