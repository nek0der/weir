## Summary

<!-- Begin with one to three sentences: the problem and resulting behavior.
     Explain the implementation, rationale, or limitations when needed.
     Wording: docs/writing-guide.md. -->

## Related issue

<!-- e.g. Closes #123. Write "Skip." if there is none. -->

## How verified

<!-- State the checks actually performed and their outcomes for every PR.
     Distinguish local checks from CI and identify unverified behavior.
     For user-visible changes, describe your manual checks or explain why
     you could not perform them.
     Examples:
       - "Launched a Debug build, dragged a pane onto a tab, and confirmed it merges."
       - "Ran make screenshot; the Needs Attention list still renders correctly in demo mode." -->

## Screenshots / video

<!-- Required for any UI change. Attach a still, plus a short clip if motion matters. -->

## Checklist

<!-- Tick applicable items only after verifying them. Leave items that do not
     apply unchecked; no explanation is needed. For an applicable check you
     could not complete, leave it unchecked and explain why in How verified. -->

- [ ] `make lint` passes locally
- [ ] `make test` passes
- [ ] `make review-core` passes (its own CI job; `make test` does not cover it)
- [ ] Tests added or updated where applicable
- [ ] User-facing strings added to `Localizable.xcstrings` with both `en` and `ja`
- [ ] Documents in `site/` updated in every language, if this changes what they describe
- [ ] Verified manually on macOS 26 or later — see "How verified" above
- [ ] Code comments are in English
