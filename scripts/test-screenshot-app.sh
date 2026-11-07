#!/usr/bin/env bash
# scripts/test-screenshot-app.sh
# Weir — self-test for bundle selection in `screenshot.sh`.
#
# `make screenshot` hands the script the app this project just built. Were the
# script to search DerivedData, it would take the newest Weir.app of any
# worktree and put another branch's build in the hero; run on its own, it takes
# this checkout's build for the same reason. This runs a copy of the script in
# a throwaway checkout, against a throwaway home whose DerivedData holds a
# newer app than the one handed over or the checkout's, with apps that have no
# executable, so nothing is ever launched: the script names the app it picked
# and stops at reading its Info.plist.
#
# Run from the repo root:
#   scripts/test-screenshot-app.sh
#
# Exits 0 on success, 1 on any failing case (with a per-case diagnostic).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# A checkout holds the script, the lookup it asks, and (unless told not to) a
# generated project, as the lookup refuses to ask xcodebuild without one.
make_checkout() {
  local root="$1"
  mkdir -p "$root/scripts"
  cp "$REPO_ROOT/scripts/screenshot.sh" "$REPO_ROOT/scripts/built-app-path.sh" "$root/scripts/"
  if [[ "${2:-}" != no-project ]]; then
    mkdir -p "$root/Weir.xcodeproj"
    : > "$root/Weir.xcodeproj/project.pbxproj"
  fi
}

CHECKOUT="$TMP/checkout"
UNGENERATED="$TMP/ungenerated"
make_checkout "$CHECKOUT"
make_checkout "$UNGENERATED" no-project

HANDED="$TMP/project/Build/Products/Release/Weir.app"
NEWER="$TMP/home/Library/Developer/Xcode/DerivedData/Other-abc/Build/Products/Release/Weir.app"
# The checkout's builds, as the stand-in xcodebuild below reports them: one
# products folder with both configurations, and one with only Debug.
CHECKOUT_RELEASE="$TMP/products/Build/Products/Release/Weir.app"
CHECKOUT_DEBUG="$TMP/products/Build/Products/Debug/Weir Dev.app"
DEBUG_ONLY="$TMP/debug-only/Build/Products/Debug/Weir Dev.app"
mkdir -p "$HANDED" "$NEWER" "$CHECKOUT_RELEASE" "$CHECKOUT_DEBUG" "$DEBUG_ONLY" "$TMP/cwd" "$TMP/bin"
touch -t 202001010000 "$HANDED" "$CHECKOUT_RELEASE" "$CHECKOUT_DEBUG" "$DEBUG_ONLY"

# `built-app-path.sh` asks xcodebuild where the checkout builds its app. The
# stand-in answers only for the checkout's own project and the Weir scheme: it
# prints the two settings the lookup reads, as `-showBuildSettings` does, for
# the folder FAKE_PRODUCTS names. Any other call fails, so a case that selects
# the checkout's app proves which project was asked.
cat > "$TMP/bin/xcodebuild" <<EOF
#!/bin/sh
case "\$*" in
  "-project $CHECKOUT/Weir.xcodeproj -scheme Weir -configuration Release -showBuildSettings") product="Weir.app" ;;
  "-project $CHECKOUT/Weir.xcodeproj -scheme Weir -configuration Debug -showBuildSettings") product="Weir Dev.app" ;;
  *) echo "unexpected xcodebuild call: \$*" >&2; exit 64 ;;
esac
echo "    BUILT_PRODUCTS_DIR = \$FAKE_PRODUCTS/Build/Products/\$6"
echo "    FULL_PRODUCT_NAME = \$product"
EOF
chmod +x "$TMP/bin/xcodebuild"
STUB_PATH="$TMP/bin:$PATH"

failures=0

# Runs the checkout's script ($1) from a scratch directory (it creates
# `.github/assets` and `build/` relative to where it runs) and prints
# everything it said.
run_script() {
  local script="$1"
  shift
  (cd "$TMP/cwd" && env HOME="$TMP/home" PATH="$STUB_PATH" WEIR_SCREENSHOT_APP= WEIR_SCREENSHOT_OUT="$TMP/cwd/hero.png" "$@" "$script" 2>&1) || true
}

# The bundle the checkout's script selected.
selected_app() {
  run_script "$CHECKOUT/scripts/screenshot.sh" "$@" | sed -n 's/^Launching: //p'
}

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  ✓ $name"
  else
    echo "  ✗ $name: got '$actual', expected '$expected'" >&2
    failures=$((failures + 1))
  fi
}

check "the app handed over wins over a newer one in DerivedData" \
  "$HANDED" "$(selected_app FAKE_PRODUCTS="$TMP/products" WEIR_SCREENSHOT_APP="$HANDED")"
check "without one, this checkout's Release app wins over a newer one in DerivedData" \
  "$CHECKOUT_RELEASE" "$(selected_app FAKE_PRODUCTS="$TMP/products")"
check "without a Release build, this checkout's Debug app is used" \
  "$DEBUG_ONLY" "$(selected_app FAKE_PRODUCTS="$TMP/debug-only")"

# A checkout without a generated project selects no bundle and says how
# to generate the project.
ungenerated="$(run_script "$UNGENERATED/scripts/screenshot.sh" FAKE_PRODUCTS="$TMP/products")"
check "without a generated project, no bundle is selected" \
  "" "$(printf '%s\n' "$ungenerated" | sed -n 's/^Launching: //p')"
check "without a generated project, the error names make xcodegen" \
  "yes" "$(grep -q 'run make xcodegen first' <<<"$ungenerated" && echo yes || echo no)"

if ((failures > 0)); then
  echo "✗ test-screenshot-app: $failures case(s) failed." >&2
  exit 1
fi
echo "✓ test-screenshot-app: 5 case(s) passed."
