# shellcheck shell=bash
# scripts/lib/cargo.sh
# Weir — find Cargo for a script Xcode runs; sourced, not executed.
#
# Usage: source "<repo>/scripts/lib/cargo.sh"; use_cargo "<what it is for>"
#
# Sets `cargo_bin` and puts its directory first on PATH. A build phase that
# runs a script sourcing this file lists it among the phase's inputFiles, so
# the script sandbox lets the script read it.

# Xcode's restricted PATH leaves out Homebrew, so we fall back to where the
# rustup formula installs its proxies. Homebrew puts `rustc` beside `cargo`,
# and Cargo runs that sibling by name when it queries the compiler, so its
# directory goes on PATH as well. The argument says what Cargo is needed for,
# so a missing Cargo names the step that stopped.
use_cargo() {
  local purpose="$1" candidate
  cargo_bin="$(command -v cargo || true)"
  if [[ -z "$cargo_bin" ]]; then
    for candidate in /opt/homebrew/opt/rustup/bin/cargo /usr/local/opt/rustup/bin/cargo; do
      if [[ -x "$candidate" ]]; then
        cargo_bin="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$cargo_bin" ]]; then
    echo "error: cargo was not found; it is needed $purpose. Install rustup with Homebrew and initialize the pinned toolchain." >&2
    exit 1
  fi
  PATH="$(dirname "$cargo_bin"):$PATH"
  export PATH
}
