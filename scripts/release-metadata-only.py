#!/usr/bin/env python3
# Weir — whether a pull request's changes are only what release-please writes.
#
# CI skips the builds and tests for the release pull request, which carries only
# a version bump and the changelog on top of code `main` has already checked. A
# branch name says who opened the pull request, not what it changes, so CI asks
# this script about the changed files instead.
#
# Usage: scripts/release-metadata-only.py <config> <manifest> < files.jsonl
#
# Each stdin line is one changed file as the GitHub API lists it, with at least
# `filename`, `status`, and `patch`. The files release-please may change come
# from its own config: the changelog, which may change in any way, and the
# manifest and the `extra-files`, where a line may change only in its version,
# and in the `extra-files` only on a line marked `x-release-please-version`.
# Exits 0 when every change is one of those, 1 when any is not (naming it on
# stderr), and 2 on unreadable input.

import json
import re
import sys

MARKER = "x-release-please-version"
# A version as release-please writes one: 0.1.20, or 1.0.0-beta.1.
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?")


def changed_blocks(patch):
    """The runs of changed lines in a unified diff, each as its removed and its
    added lines, without their sign. A context line or a hunk header ends a
    run. Lines split at LF only: a lone CR is part of its line, as Git keeps
    it, and YAML would read it as a line break."""
    blocks, removed, added = [], [], []
    for line in patch.split("\n"):
        if line.startswith("-"):
            if added:
                # A removal after an addition is not one rewrite of lines in place.
                blocks.append((removed, added))
                removed, added = [], []
            removed.append(line[1:])
        elif line.startswith("+"):
            added.append(line[1:])
        else:
            if removed or added:
                blocks.append((removed, added))
            removed, added = [], []
    if removed or added:
        blocks.append((removed, added))
    return blocks


def is_version_bump(before, after, needs_marker):
    """Whether `after` is `before` with only its versions changed, each where it stood."""
    if needs_marker and not before.rstrip().endswith(MARKER):
        return False
    if VERSION.search(before) is None or VERSION.search(after) is None:
        return False
    # Splitting at the versions keeps the text between them, so the two lines
    # must agree on everything but the versions and on where each one stands.
    return VERSION.split(before) == VERSION.split(after)


def refusal(entry, changelog, manifest, extra_files):
    """Why `entry` is not release metadata, or None when it is."""
    name = entry.get("filename", "")
    if entry.get("status") != "modified" or entry.get("previous_filename"):
        return f"{name}: {entry.get('status')}, not modified in place"
    if name != changelog and name != manifest and name not in extra_files:
        return f"{name}: not a file release-please writes"
    # The API leaves `patch` out of a diff too large to show, which we cannot
    # check, so it counts as a change.
    patch = entry.get("patch")
    if not patch:
        return f"{name}: no patch to check"
    blocks = changed_blocks(patch)
    if not blocks:
        return f"{name}: no changed line to check"
    if name == changelog:
        return None
    # release-please rewrites a version where it stands, so each run of removed
    # lines is followed at once by as many added lines, each the same line with
    # another version. A line moved elsewhere in the file is a different change.
    for removed, added in blocks:
        if len(removed) != len(added):
            return f"{name}: lines were added, removed, or moved, not only rewritten"
        for before, after in zip(removed, added):
            if not is_version_bump(before, after, needs_marker=name != manifest):
                return f"{name}: a changed line is not a version bump: {after.strip()}"
    return None


def main():
    if len(sys.argv) != 3:
        print("usage: release-metadata-only.py <config> <manifest> < files.jsonl", file=sys.stderr)
        return 2
    config_path, manifest = sys.argv[1], sys.argv[2]
    try:
        with open(config_path, encoding="utf-8") as config_file:
            packages = json.load(config_file)["packages"]
        entries = [json.loads(line) for line in sys.stdin if line.strip()]
    except (OSError, ValueError, KeyError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    # Our config has one package at the root, whose changelog keeps the default
    # name. A package elsewhere would need its own folder prefixed here.
    if list(packages) != ["."]:
        print("error: the config has a package other than the root one", file=sys.stderr)
        return 2
    package = packages["."]
    changelog = package.get("changelog-path", "CHANGELOG.md")
    extra_files = {
        item if isinstance(item, str) else item.get("path", "")
        for item in package.get("extra-files", [])
    }
    if not entries:
        print("no changed files", file=sys.stderr)
        return 1
    reasons = [reason for entry in entries if (reason := refusal(entry, changelog, manifest, extra_files))]
    for reason in reasons:
        print(reason, file=sys.stderr)
    return 1 if reasons else 0


if __name__ == "__main__":
    sys.exit(main())
