#!/usr/bin/env bash
# Weir — self-test for the checks `package-dmg.sh` makes before building a dmg.
#
# A real run needs a notarized Developer ID build, so each case runs a copy of
# the script on a fake Weir.app with `codesign`, `spctl`, `create-dmg`, and
# `xcodebuild` replaced on PATH. The fake `create-dmg` stops the run, so
# reaching it means every check before it passed, and nothing is built,
# submitted, or written outside the temporary directory.
#
# Run from the repo root:
#   scripts/test-package-dmg.sh
#
# Exits 0 on success, 1 on any failing case (with a per-case diagnostic).
# Needs macOS for `plutil`, like the script itself.

# The case mutations are invoked indirectly through run_case, and the stand-in
# tools and the unexpanded version are written with their `$` kept literal.
# shellcheck disable=SC2329,SC2016

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="${REPO_ROOT}/scripts/package-dmg.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: script not found at $SCRIPT" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passes=0
fails=0

# Lays out a repository copy holding the script, a fake app with version
# 1.2.3, and the stand-in tools, under the directory given as $1.
make_fixture() {
  local root="$1"
  mkdir -p "$root/scripts" "$root/bin" "$root/Weir.app/Contents/Resources" "$root/Weir.xcodeproj"
  cp "$SCRIPT" "$root/scripts/package-dmg.sh"
  cp "$REPO_ROOT/scripts/built-app-path.sh" "$root/scripts/built-app-path.sh"
  : > "$root/Weir.xcodeproj/project.pbxproj"
  # Without an argument the script asks built-app-path.sh, which asks
  # xcodebuild. This stand-in answers only for the fixture's own project,
  # scheme, and Release configuration, naming the fixture's app; any other call
  # fails, so a case that reaches the dmg step proves which build was asked for.
  printf '#!/bin/sh
if [ "$*" != "-project %s/Weir.xcodeproj -scheme Weir -configuration Release -showBuildSettings" ]; then
  echo "unexpected xcodebuild call: $*" >&2
  exit 64
fi
echo "    BUILT_PRODUCTS_DIR = %s"
echo "    FULL_PRODUCT_NAME = Weir.app"
' "$root" "$root" > "$root/bin/xcodebuild"
  plutil -create xml1 "$root/Weir.app/Contents/Info.plist"
  plutil -insert CFBundleShortVersionString -string 1.2.3 "$root/Weir.app/Contents/Info.plist"
  : > "$root/Weir.app/Contents/Resources/THIRD-PARTY-NOTICES"
  printf '#!/bin/sh\nexit 0\n' > "$root/bin/codesign"
  # The fake spctl prints the app's path and then whatever the case left in
  # spctl-output, as `spctl --assess --verbose` does.
  printf '#!/bin/sh\nprintf "%%s: " "$5"\ncat "%s/spctl-output"\n' "$root" > "$root/bin/spctl"
  printf 'accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Example (ABCDE12345)\n' \
    > "$root/spctl-output"
  printf '#!/bin/sh\necho REACHED-CREATE-DMG >&2\nexit 1\n' > "$root/bin/create-dmg"
  chmod +x "$root/bin/"*
}

# $1 case name, $2 expected verdict ("reaches" the dmg step or "stops" before
# it), then a command that mutates the fixture whose root it receives last.
run_case() {
  local name="$1" expect="$2"
  shift 2
  local root
  root="$(mktemp -d -p "$TMP")"
  make_fixture "$root"
  "$@" "$root"

  local output actual app_argument=("$root/Weir.app")
  [[ -f "$root/no-argument" ]] && app_argument=()
  output="$(PATH="$root/bin:$PATH" "$root/scripts/package-dmg.sh" ${app_argument[@]+"${app_argument[@]}"} 2>&1 || true)"
  if grep -q REACHED-CREATE-DMG <<<"$output"; then
    actual="reaches"
  else
    actual="stops"
  fi
  if [[ "$actual" == "$expect" ]]; then
    printf '  ok   %s\n' "$name"
    passes=$((passes + 1))
  else
    printf '  FAIL %s (expected %s, got %s)\n%s\n' "$name" "$expect" "$actual" "$output" >&2
    fails=$((fails + 1))
  fi
}

unchanged() { :; }

# Gatekeeper's verdict for a Developer ID app with no ticket on a release that
# still lets one through.
accepted_without_ticket() {
  printf 'accepted\nsource=Developer ID\n' > "$1/spctl-output"
}
rejected() { printf 'rejected\nsource=Unnotarized Developer ID\n' > "$1/spctl-output"; }
bad_signature() { printf '#!/bin/sh\nexit 1\n' > "$1/bin/codesign"; }
no_version() { plutil -remove CFBundleShortVersionString "$1/Weir.app/Contents/Info.plist"; }
unexpanded_version() {
  plutil -replace CFBundleShortVersionString -string '$(MARKETING_VERSION)' "$1/Weir.app/Contents/Info.plist"
}
empty_version() { plutil -replace CFBundleShortVersionString -string '' "$1/Weir.app/Contents/Info.plist"; }
unreadable_plist() { printf 'not a plist' > "$1/Weir.app/Contents/Info.plist"; }
# Runs the script with no app path, so it must find the checkout's own build.
no_argument() { : > "$1/no-argument"; }
# The same, for a checkout that has not built Release.
no_argument_no_build() {
  no_argument "$1"
  rm -rf "$1/Weir.app"
}
# The same, for a checkout whose project has not been generated.
no_argument_no_project() {
  no_argument "$1"
  rm -rf "$1/Weir.xcodeproj"
}

run_case "a notarized app with a version reaches the dmg step" reaches unchanged
run_case "an app accepted without a notarization ticket stops" stops accepted_without_ticket
run_case "an app Gatekeeper rejects stops" stops rejected
run_case "an app whose signature does not verify stops" stops bad_signature
run_case "an app with no version stops" stops no_version
run_case "an app with an unexpanded version stops" stops unexpanded_version
run_case "an app with an empty version stops" stops empty_version
run_case "an app whose Info.plist does not parse stops" stops unreadable_plist
run_case "without a path, this checkout's Release app reaches the dmg step" reaches no_argument
run_case "without a path or a Release build, it stops" stops no_argument_no_build
run_case "without a path or a generated project, it stops" stops no_argument_no_project

echo
if [[ $fails -eq 0 ]]; then
  echo "test-package-dmg: $passes case(s) passed."
  exit 0
fi
echo "test-package-dmg: $fails failure(s) of $((passes + fails)) case(s)." >&2
exit 1
