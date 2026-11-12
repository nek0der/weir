#!/usr/bin/env bash
# Weir — self-test for `check-adapter-purity.sh`.
#
# Without this, a pattern that stopped matching, or a test module that hid
# the code after it, would pass an adapter that reads the host.
#
# Run from the repo root:
#   scripts/test-check-adapter-purity.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECK="${REPO_ROOT}/scripts/check-adapter-purity.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0

# A tree with one provider crate whose source is `$2`.
tree() {
  mkdir -p "$TMP/$1/weir-provider-example/src"
  printf '%s\n' "$2" > "$TMP/$1/weir-provider-example/src/lib.rs"
}

expect_pass() {
  "$CHECK" "$TMP/$1" >/dev/null 2>&1 \
    || { echo "✗ $2 was refused" >&2; failures=$((failures + 1)); }
}

expect_refusal() {
  if output="$("$CHECK" "$TMP/$1" 2>&1)"; then
    echo "✗ $2 passed" >&2
    failures=$((failures + 1))
  elif ! grep -q "$3" <<<"$output"; then
    echo "✗ $2 was refused for another reason: $output" >&2
    failures=$((failures + 1))
  fi
}

tree pure 'pub fn normalize(at: std::time::SystemTime) -> std::time::SystemTime { at }
// std::fs::read in a comment is not a call.
#[cfg(test)]
mod tests {
    #[test]
    fn reads_a_fixture() {
        let _ = std::fs::read("fixture.json");
        let _ = std::time::SystemTime::now();
    }
}'
expect_pass pure "an adapter that reads only its input, with tests that read the disk"

tree disk 'pub fn real(path: &std::path::Path) -> Option<std::path::PathBuf> { std::fs::canonicalize(path).ok() }'
expect_refusal disk "a canonicalize through std::fs" "reads the file system"

tree imported 'use std::fs;
pub fn bytes() -> Vec<u8> { fs::read("x").unwrap_or_default() }'
expect_refusal imported "fs:: after an import" "reads the file system"

tree path 'pub fn here(path: &std::path::Path) -> bool { path.exists() }'
expect_refusal path "a path that checks the disk" "reads the file system"

tree clock 'use std::time::SystemTime;
pub fn now() -> SystemTime { SystemTime::now() }'
expect_refusal clock "a read of the clock" "reads the clock"

tree environment 'pub fn home() -> Option<String> { std::env::var("HOME").ok() }'
expect_refusal environment "a read of the environment" "reads the environment"

tree process 'pub fn run() { let _ = std::process::Command::new("git"); }'
expect_refusal process "a process started" "reads another process"

tree aliased 'use std::{fs as disk};
pub fn bytes() -> Vec<u8> { disk::read("x").unwrap_or_default() }'
expect_refusal aliased "std::fs imported under another name" "reads the file system"

tree clock_alias 'use std::time::SystemTime as Clock;
pub fn now() -> Clock { Clock::now() }'
expect_refusal clock_alias "the clock imported under another name" "reads the clock"

tree path_function 'pub fn here(path: &std::path::Path) -> bool { std::path::Path::exists(path) }'
expect_refusal path_function "Path::exists called as a function" "reads the file system"

tree empty_tests 'pub fn normalize() {}
#[cfg(test)]
mod tests {}'
expect_pass empty_tests "an empty test module"

tree shared_tests 'pub fn normalize() {}
#[cfg(test)]
pub(crate) mod tests {
    pub(crate) fn fixture() {}
}'
expect_pass shared_tests "a test module other modules share"

tree hidden '#[cfg(test)]
mod tests {}
pub fn later() -> Vec<u8> { std::fs::read("x").unwrap_or_default() }'
expect_refusal hidden "code after the test module" "must open a module that is the last item"

tree hidden_function '#[cfg(test)]
fn fixture() {}
pub fn host() {
    let _ = std::fs::read("x");
}'
expect_refusal hidden_function "a test-only function hiding the code after it" "must open a module that is the last item"

mkdir -p "$TMP/none"
expect_refusal none "a tree with no provider crates" "no rust/weir-provider-"

if [ "$failures" -ne 0 ]; then
  echo "test-check-adapter-purity: $failures failure(s)" >&2
  exit 1
fi
echo "✓ test-check-adapter-purity: all cases behave."
