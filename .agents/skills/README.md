# Skills

Skills are procedures a coding agent loads when a task needs them. They extend
`AGENTS.md`, which every session reads, with the steps, commands, and checks of
one kind of work. The format is the open Agent Skills one (`SKILL.md` with
`name` and `description` frontmatter).

Codex reads skills here. Claude Code reads only `.claude/skills/`, so each
skill has a link there, `.claude/skills/<name>` pointing at
`../../.agents/skills/<name>`. One link per skill, not one for the whole
folder: Claude Code's documentation says it follows a link to a skill's
folder, and a link to the folder above has been reported not to load. A new skill adds
its link (`ln -s ../../.agents/skills/<name> .claude/skills/<name>`) and its
row in [Available skills](#available-skills) in the same pull request.

## Available skills

| Skill | Use it for |
| --- | --- |
| [design-tests](design-tests/SKILL.md) | Designing and reviewing test cases, assertions, fixtures, and consolidation while preserving regression coverage. |
| [verify-in-app](verify-in-app/SKILL.md) | Checking a change in a running Debug app through the verification channel. |

## When something is a skill

A skill is a procedure that is:

- too long or too specific for `AGENTS.md` (a multi-step workflow, a
  diagnostic sequence, commands with their pitfalls),
- needed only for some tasks, not every session,
- complete enough to follow on its own.

It is not a skill when it is a one-line rule (that goes in `AGENTS.md`), a fact
every session needs (`AGENTS.md`), or the reason behind a design (an ADR under
`docs/adr/`). A skill links to its ADR rather than repeating the reasoning.

## Layout

```
.agents/skills/
├── README.md              # this file
└── <name>/
    ├── SKILL.md           # required: frontmatter, then the procedure
    └── <topic>.md         # optional: detail SKILL.md links to, one level deep
```

Scripts a skill runs live in `scripts/`, with the rest of the repository's
tools that `make` and people use, not inside the skill.

## Writing one

- **Name**: short, lowercase, hyphenated, for the activity (`verify-in-app`).
  No `weir-` prefix: being in this folder already scopes it.
- **Description**: third person; what it covers and when to use it, with the
  words a request would use and the files or commands it involves. It is all
  an agent sees when deciding to load the skill.
- **Body**: lead with when to use it and when not to, then the steps, then the
  pitfalls, then how to check the result. Tell the agent what to do, not what
  to know; leave out what an agent already knows.
- **Size**: `SKILL.md` stays under 500 lines; longer detail goes in a linked
  file, and a linked file never links further.
- **Language**: English, like the rest of the repository.
- **No dates**; say what is true of the code. A fact about another program
  names the version it was seen on, as `docs/README.md` says.

## Keeping them true

`claude plugin validate .agents/skills` checks every skill's frontmatter. It
reads the real folder; it does not follow the links in `.claude/skills`.

A skill is code documentation, and it rots the same way:

- A pull request that changes what a skill describes (its commands, flags,
  files, or behavior) updates the skill in the same pull request.
- Every skill ends with a way to check that following it worked, ideally a
  command (`make check-automation` for `verify-in-app`). When that check
  fails after a change, the skill or the code is wrong; fix the one that is.
- A skill is written from a run that worked, then tried by a fresh agent with
  only the skill to go on; what that agent misses goes back into the skill.
- A skill nobody uses, or one whose subject is gone, is deleted rather than
  left to mislead.
