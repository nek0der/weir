#!/usr/bin/env bash
# Weir — fail when a provider adapter reads the host instead of its input.
#
# ADR 0004: an adapter never touches the file system. It turns a payload and
# the `HookContext` the runtime hands it into events, so a recorded payload
# with its context normalizes the same way on any machine, and the fixtures
# can replay it. The runtime reads the host's facts once (paths resolved on
# disk, the clock) and passes them in `HookContext`. A call that reads the
# disk, the clock, the environment, or another process from an adapter's own
# code breaks that, and a new provider would copy it, so this check refuses
# one in the production code of every `rust/weir-provider-*` crate. Tests may
# read the disk for their fixtures.
#
# Each source file is read up to its `#[cfg(test)]` module, which must be the
# last item in the file, so nothing after it escapes the check.
#
# Usage: scripts/check-adapter-purity.sh [RUST_DIRECTORY]
# Default: rust/ in this checkout.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIRECTORY="${1:-${REPO_ROOT}/rust}"

python3 -I - "$RUST_DIRECTORY" <<'PY'
import pathlib
import re
import sys

rust_directory = pathlib.Path(sys.argv[1])

# What reads the host, as it is spelled in code: a module path, an import
# under another name, and a path's own methods, called on a path or through
# `Path::`, since `Path::exists` and its kin read the disk as `std::fs` does.
# A pattern check, not a compiler: it catches the usual spellings, and review
# catches the rest.
FORBIDDEN = [
    (re.compile(r"\bstd::fs\b|(?<![\w:])fs::|\bfs\s+as\b"), "the file system"),
    (re.compile(r"\bFile::|\bOpenOptions\b"), "the file system"),
    (re.compile(r"\bcanonicalize\s*\("), "the file system"),
    (re.compile(r"(\.|::)\s*(exists|try_exists|is_file|is_dir|is_symlink|metadata|symlink_metadata|read_dir|read_link)\s*\("), "the file system"),
    (re.compile(r"\b(SystemTime|Instant)\s*(::now\b|\bas\b)"), "the clock"),
    (re.compile(r"\bstd::env\b|(?<![\w:])env::"), "the environment"),
    (re.compile(r"\bstd::process\b|\bCommand::new\b"), "another process"),
    (re.compile(r"\bstd::net\b"), "the network"),
]
TEST_MODULE = re.compile(r"^#\[cfg\(test\)\]\s*$")
MODULE = re.compile(r"^(pub(\([\w:]+\))?\s+)?mod\s+\w+\s*\{\s*(\}\s*)?$")

crates = sorted(path for path in rust_directory.glob("weir-provider-*") if path.is_dir())
if not crates:
    print(f"error: no rust/weir-provider-* crates under {rust_directory}", file=sys.stderr)
    sys.exit(1)

problems = []
for crate in crates:
    for source in sorted((crate / "src").rglob("*.rs")):
        lines = source.read_text(encoding="utf-8").splitlines()
        end = next((index for index, line in enumerate(lines) if TEST_MODULE.match(line)), len(lines))
        if end < len(lines):
            # The attribute must open a module, whose closing brace, at the
            # left margin, is the file's last line with anything on it.
            declaration = lines[end + 1] if end + 1 < len(lines) else ""
            if MODULE.match(declaration) and declaration.rstrip().endswith("}"):
                closing = end + 1
            elif MODULE.match(declaration):
                closing = next((index for index in range(end + 2, len(lines)) if lines[index] == "}"), None)
            else:
                closing = None
            if closing is None or any(line.strip() for line in lines[closing + 1:]):
                problems.append(f"{source}:{end + 1}: #[cfg(test)] must open a module that is the last item in the file")
        for number, line in enumerate(lines[:end], start=1):
            code = line.strip()
            if code.startswith("//"):
                continue
            for pattern, reads in FORBIDDEN:
                if pattern.search(code):
                    problems.append(f"{source}:{number}: reads {reads}: {code}")
                    break

if problems:
    print("error: a provider adapter reads the host (ADR 0004); have the runtime read it and pass it in HookContext:", file=sys.stderr)
    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    sys.exit(1)
print(f"✓ check-adapter-purity: no host reads found in {len(crates)} provider crates.")
PY
