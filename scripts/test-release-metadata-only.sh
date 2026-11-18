#!/usr/bin/env bash
# Weir — self-test for `release-metadata-only.py`, which decides whether CI may
# skip a pull request's builds and tests as release metadata.
#
# Each case feeds the script a pull request files list shaped like the GitHub
# API's, checked against this repository's release-please config.
#
# Run from the repo root:
#   scripts/test-release-metadata-only.sh
#
# Exits 0 on success, 1 on any failing case.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="${REPO_ROOT}/scripts/release-metadata-only.py"
CONFIG="${REPO_ROOT}/.github/release-please-config.json"
MANIFEST=".github/.release-please-manifest.json"

passes=0
fails=0

# One files-list entry as a JSON line: $1 file name, $2 status, $3 patch
# (omitted from the entry when `-`).
entry() {
  if [[ "$3" == "-" ]]; then
    jq -cn --arg name "$1" --arg status "$2" '{filename: $name, status: $status}'
  else
    jq -cn --arg name "$1" --arg status "$2" --arg patch "$3" '{filename: $name, status: $status, patch: $patch}'
  fi
}

manifest_bump="$(entry "$MANIFEST" modified $'@@ -1,3 +1,3 @@\n {\n-  ".": "0.1.19"\n+  ".": "0.1.20"\n }')"
changelog="$(entry CHANGELOG.md modified $'@@ -1,5 +1,7 @@\n # Changelog\n+\n+## [0.1.20]')"
project_bump="$(entry project.yml modified $'@@ -33,8 +33,8 @@\n-    MARKETING_VERSION: "0.1.19" # x-release-please-version\n+    MARKETING_VERSION: "0.1.20" # x-release-please-version')"

# $1 case name, $2 expected exit status, then the files list's lines.
run_case() {
  local name="$1" expected="$2" status=0 output
  shift 2
  output="$(printf '%s\n' "$@" | python3 -I "$SCRIPT" "$CONFIG" "$MANIFEST" 2>&1)" || status=$?
  if [[ "$status" == "$expected" ]]; then
    printf '  ok   %s\n' "$name"
    passes=$((passes + 1))
  else
    printf '  FAIL %s (expected exit %s, got %s)\n%s\n' "$name" "$expected" "$status" "$output" >&2
    fails=$((fails + 1))
  fi
}

run_case 'a version bump with its changelog is metadata' 0 \
  "$manifest_bump" "$changelog" "$project_bump"
run_case 'the changelog alone is metadata' 0 "$changelog"
run_case 'a source file beside the bump is not metadata' 1 \
  "$manifest_bump" "$project_bump" "$(entry Weir/App/WeirLaunch.swift modified $'@@ -1 +1 @@\n-a\n+b')"
run_case 'an unmarked line in an extra file is not metadata' 1 \
  "$(entry project.yml modified $'@@ -33,8 +33,9 @@\n+    OTHER_SWIFT_FLAGS: "-DX"\n-    MARKETING_VERSION: "0.1.19" # x-release-please-version\n+    MARKETING_VERSION: "0.1.20" # x-release-please-version')"
run_case 'a manifest line that is not a version is not metadata' 1 \
  "$(entry "$MANIFEST" modified $'@@ -1,3 +1,3 @@\n+  "other": true')"
run_case 'an extra file the API gives no patch for is not metadata' 1 "$(entry project.yml modified -)"
run_case 'a changelog the API gives no patch for is not metadata' 1 "$(entry CHANGELOG.md modified -)"
run_case 'an empty patch is not metadata' 1 "$(entry .github/.release-please-manifest.json modified '')"
run_case 'a removed version line is not metadata' 1 \
  "$(entry project.yml modified $'@@ -36,2 +36,1 @@\n-    MARKETING_VERSION: "0.1.19" # x-release-please-version')"
run_case 'a renamed key on a marked line is not metadata' 1 \
  "$(entry project.yml modified $'@@ -36 +36 @@\n-    MARKETING_VERSION: "0.1.19" # x-release-please-version\n+    OTHER_VERSION: "0.1.20" # x-release-please-version')"
run_case 'a manifest key changed beside its version is not metadata' 1 \
  "$(entry "$MANIFEST" modified $'@@ -1,3 +1,3 @@\n-  ".": "0.1.19"\n+  "x": "0.1.20"')"
run_case 'a manifest version that is not one is not metadata' 1 \
  "$(entry "$MANIFEST" modified $'@@ -1,3 +1,3 @@\n-  ".": "0.1.19"\n+  ".": "latest"')"
run_case 'a manifest version that was emptied is not metadata' 1 \
  "$(entry "$MANIFEST" modified $'@@ -1,3 +1,3 @@\n-  ".": "0.1.19"\n+  ".": ""')"
run_case 'a marked line moved to another hunk is not metadata' 1 \
  "$(entry project.yml modified $'@@ -10,2 +10,1 @@\n-    MARKETING_VERSION: "0.1.19" # x-release-please-version\n debug:\n@@ -40,1 +40,2 @@\n release:\n+    MARKETING_VERSION: "0.1.20" # x-release-please-version')"
run_case 'a change after a carriage return inside a line is not metadata' 1 \
  "$(entry project.yml modified $'@@ -36 +36 @@\n-    MARKETING_VERSION: "0.1.19" # x-release-please-version\n+    MARKETING_VERSION: "0.1.20"\rOTHER: 1 # x-release-please-version')"
run_case 'a version moved into the key is not metadata' 1 \
  "$(entry "$MANIFEST" modified $'@@ -1,3 +1,3 @@\n-  ".": "0.1.19"\n+  ".0.1.20": ""')"
run_case 'a renamed changelog is not metadata' 1 "$(entry CHANGELOG.md renamed -)"
run_case 'an added file is not metadata' 1 "$(entry CHANGELOG.md added $'@@ -0,0 +1 @@\n+x')"
run_case 'no changed files is not metadata' 1
run_case 'a line that is not JSON is unreadable' 2 'not json'

echo
if [[ $fails -eq 0 ]]; then
  echo "test-release-metadata-only: $passes case(s) passed."
  exit 0
fi
echo "test-release-metadata-only: $fails failure(s) of $((passes + fails)) case(s)." >&2
exit 1
