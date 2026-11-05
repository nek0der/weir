# Writing guide

This guide explains how to write code comments, documents, commit messages,
and pull requests for Weir. It applies to human contributors and coding agents,
but not to chat responses. Read the common rules and the section relevant to
your task. Examples illustrate wording, not verified changes to Weir.

The [language policy](../CONTRIBUTING.md#language-policy) specifies the
language to use for each kind of contribution. The [document guide](README.md)
defines structure and content rules for documents under `docs/`, including
ADRs. The
[site guide](../site/README.md) defines the corresponding rules for site pages.
Follow those guides where their requirements differ from the general advice
here. The [agent guide](../AGENTS.md) defines code and Git conventions, and
the [PR template](../.github/pull_request_template.md) defines
the required PR sections. Other contributor and agent instructions may
summarize essential wording rules and link here. Keep detailed rules and
examples in this guide.

## Common wording

- Use plain, precise language and US English spelling and grammar.
  Keep the same term for the same concept; use the names in the UI and code.
- State the condition, behavior, or consequence. Replace vague claims such
  as "improves robustness" or "handles this properly" with a specific
  description of the behavior.
- Prefer active voice when the actor matters. Name the component or operation
  instead of leaving "this" or "it" with an unclear referent.
- Use a neutral written tone. Avoid conversational asides, promotional claims,
  emoji, and decorative symbols. Describe mechanisms directly instead of using
  metaphors to explain them; preserve established product and technical terms.
  Support claims about safety, correctness, or performance with evidence.
- Keep each paragraph about one point. Use lists for parallel items or
  ordered actions. Include the context needed to understand a decision;
  brevity is not a reason to omit a prerequisite or a limitation.
- Put identifiers, paths, commands, and configuration keys in backticks.
  Preserve their spelling. Follow the document guide for links and layout.
- Describe the resulting behavior rather than the author's sequence of
  attempts. Keep history only when it explains a current constraint or a
  migration. An issue number or external link supplements the explanation;
  it does not replace it.

## Sentence forms

Choose the sentence form that fits the text's purpose. The Swift API summary
forms below follow the Swift API Design Guidelines. Using `we` to explain
implementation choices and following Conventional Commits for titles are
Weir conventions.

| Text | Form | Example |
| --- | --- | --- |
| Function or method documentation summary | Present-tense verb phrase with the declaration as the implied subject; not an instruction. | `Returns the selected pane, or nil when the window has no selection.` |
| Initializer documentation summary | Describes what it creates. | `Creates a store that writes snapshots to the supplied directory.` |
| Type or property documentation summary | Noun phrase describing the entity or value. | `The identifier of the pane selected in this window.` |
| Boolean property documentation summary | Describes the condition represented by the value. | `Whether the pane has keyboard focus.` |
| Implementation comment | Complete sentence explaining a reason, constraint, or non-obvious effect. | `We retain the previous snapshot because decoding may fail during migration.` |
| Constraint directed at a caller or maintainer | An instruction with its reason. | `Keep the buffer alive until the callback returns; the callback borrows its bytes.` |
| Contributor or user procedure | Imperative verb naming the action. | `Run the affected tests before opening the PR.` |
| Commit or PR title | Imperative verb after the Conventional Commits prefix. | `fix(session): preserve saved projects when decoding fails` |
| PR body or explanatory document | Complete sentences describing the problem and resulting behavior. | `A failed decode previously replaced saved projects with an empty list.` |

Start comment sentences with a capital letter and end them with a period.
Documentation summaries also end with a period, even when they are phrases
rather than complete sentences. Headings, commit subjects, identifiers, and
the required Swift file banners do not need a period.

## Code comments

### API documentation

Use documentation comments to describe the API contract: the result,
side effects, preconditions, errors, ownership, and lifetime when relevant.
For Swift functions and methods, use a third-person present-tense verb such
as `Returns`, `Opens`, or `Updates`, rather than the imperative `Return` or
`Open`. These are examples, not a fixed vocabulary. Describe what an initializer
creates. Describe a type or property with a noun phrase, or use a clause such
as `Whether ...` for a Boolean value or `What ...` when that describes the
value more clearly. Use the same descriptive summary forms in Weir's Rust
documentation, with rustdoc markup for details. Write additional explanations
in complete sentences. Use the imperative for instructions to callers.

Do not force `we` into API summaries. Do not repeat the declaration in prose
when that adds no information. Explain non-obvious optional values, sentinel
values, and failure behavior rather than merely naming the type.

When a Swift API's inputs or errors need explanation, combine the summary with
parameter and error documentation. A result already explained in the summary
does not need a separate `- Returns` section unless more detail is needed.
For example:

```swift
/// Reads the snapshot at `url`, or returns `nil` if the file does not exist.
///
/// - Parameter url: A file URL identifying the saved snapshot.
/// - Throws: An error if an existing file cannot be read or decoded.
```

### Implementation comments

Explain why a non-obvious step or constraint exists. When describing our
implementation choices, use `we` or `our`, not `I`. A concrete subject is also
appropriate when stating behavior, such as "The callback can arrive after the
pane closes." Keep comments about the code and its constraints, not the
conversation or the person who wrote it.

Avoid narrating individual statements. For example, a comment saying
`// Check the generation.` adds little above a generation comparison. A more
useful comment explains why the check is needed:

```swift
// We discard older results because the window may have switched projects
// while the request was running.
```

Write constraints in the imperative when they instruct a future maintainer,
and explain what would break. Do not use an imperative merely to narrate what
the next line already does. Keep required ownership and concurrency safety
arguments near the declarations they justify.

Update comments when the behavior they describe changes. Explain when a
workaround is needed and, if known, when it can be removed. Include enough
context to understand the constraint without opening a supporting link.

## Commit messages and pull requests

Use the repository's Conventional Commits format and the existing PR template.
The title names the concrete change in the imperative: `preserve`, not
`preserves`, `preserved`, or `preserving`. Prefer the observable effect to a
private helper's name. After the prefix, start with a lowercase verb and omit
the final period; this is a Weir convention, not a requirement of the external
guides. Preserve the capitalization of identifiers and proper names.
Follow the agent guide for scopes and attribution. For a standalone commit
that needs explanation, leave a blank line after the subject and describe
the reason, impact, or tradeoff that the diff cannot show.

Write for a contributor who has not read the chat or worked on this area.
In the template's Summary, begin with one to three sentences explaining the
problem and resulting behavior. Add paragraphs when the reviewer needs the
implementation and its rationale, related documentation changes, or remaining
limitations. Scale detail to the change; a small change may need only the
opening paragraph.

For example, replace "Improve session restoration robustness" with:

> A failed decode previously replaced saved projects with an empty list.
> Restoration now reports the failure and preserves the saved file so the
> user can recover it.

- Omit file lists and call-by-call explanations that do not help explain the
  change. Include a discarded approach only when it explains a decision the
  reviewer needs to assess.
- State compatibility and default-behavior changes, who is affected, and any
  required action. Explain changed defaults even when no migration is needed.
- Describe test or build changes directly when those are the purpose of the
  PR.
- In How verified, report checks actually performed and their outcomes.
  Distinguish local checks, CI results, and unverified behavior. A demo run
  does not establish normal-session or approval-service behavior.
- Mark checklist items as complete only after verifying them.

## Documents

Explain behavior in declarative sentences and actions in imperative steps.
Define unfamiliar terms before relying on them. Follow the applicable
document or site guide for structure, content scope, and formatting; use the
document guide's separate ADR rules for decision records.

## Before submitting

Read the finished text from the perspective of someone who has not seen the
chat:

- Does each statement match the code or the evidence actually collected?
- Is the sentence form appropriate for its purpose?
- Are the trigger, consequence, and any required action clear?
- Can a sentence be removed because it repeats the code or another sentence?
- Do terminology, punctuation, and links remain consistent?

Apply this guide to new or substantively edited text. Do not rewrite unrelated
comments or documents solely to normalize their wording.

## References

These guides inform the distinctions above; they do not add blanket rules to
Weir or override its project conventions.

- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/):
  documentation summaries and declaration-specific forms.
- [Google C++ Style Guide](https://google.github.io/styleguide/cppguide.html#Comments):
  API contracts, implementation explanations, and readable comments.
- [Google change descriptions](https://google.github.io/eng-practices/review/developer/cl-descriptions.html):
  imperative subjects and the context needed by future readers.
