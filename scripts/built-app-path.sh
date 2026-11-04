#!/usr/bin/env bash
# scripts/built-app-path.sh
# Weir — print where this checkout builds its app for a configuration.
#
# Usage: scripts/built-app-path.sh <Debug|Release> [PROJECT] [SCHEME]
#
# PROJECT defaults to this checkout's Weir.xcodeproj and SCHEME to Weir; the
# Makefile passes its own PROJECT and SCHEME, so a PROJECT or SCHEME given to
# make still applies. A relative PROJECT is read from the current directory,
# as xcodebuild reads it.
#
# Prints the path whether or not the app has been built yet; the caller checks
# that it exists. It prints nothing and exits non-zero when the path cannot be
# read in full, so a caller never acts on half an answer. Every script and make
# target that needs this checkout's app asks here.
#
# We ask xcodebuild rather than search DerivedData: each checkout and worktree
# has its own folder there, with a hash we cannot predict, so the newest
# Weir.app under it may be another branch's build. The Debug and Release
# products are named differently (Weir Dev.app and Weir.app), which the build
# settings also say.

set -euo pipefail

usage() {
  echo "usage: scripts/built-app-path.sh <Debug|Release> [PROJECT] [SCHEME]" >&2
  exit 2
}

[[ $# -ge 1 && $# -le 3 ]] || usage
configuration="$1"
case "$configuration" in
  Debug | Release) ;;
  *) usage ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="${2:-$repo_root/Weir.xcodeproj}"
[[ "$project" == /* ]] || project="$PWD/$project"
scheme="${3:-Weir}"

# The project is generated and not tracked, so a fresh checkout has none.
# xcodebuild would then say only that it found no project.
if [[ ! -f "$project/project.pbxproj" ]]; then
  echo "error: $project has not been generated; run make xcodegen first" >&2
  exit 1
fi

settings="$(xcodebuild -project "$project" -scheme "$scheme" -configuration "$configuration" \
  -showBuildSettings 2>/dev/null)" || {
  echo "error: xcodebuild could not read the build settings of $project (scheme $scheme)" >&2
  exit 1
}

# The last of each setting: the scheme prints the app's settings after those
# of the tools it embeds.
awk -F' = ' '
    / BUILT_PRODUCTS_DIR = / { d = $2 }
    / FULL_PRODUCT_NAME = / { n = $2 }
    END {
      if (d == "" || n == "") exit 1
      print d "/" n
    }' <<<"$settings" || {
  echo "error: the build settings of $project name no built app for $configuration" >&2
  exit 1
}
