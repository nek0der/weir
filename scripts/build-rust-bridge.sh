#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=scripts/lib/cargo.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/cargo.sh"

build_architecture="${CURRENT_ARCH:-}"
if [[ -z "$build_architecture" || "$build_architecture" == "undefined_arch" ]]; then
  build_architecture="${ARCHS:-${NATIVE_ARCH_ACTUAL:-}}"
fi

case "$build_architecture" in
  arm64)
    rust_target="aarch64-apple-darwin"
    ;;
  x86_64)
    rust_target="x86_64-apple-darwin"
    ;;
  *)
    echo "error: unsupported Xcode architecture: ${build_architecture:-unknown}" >&2
    exit 1
    ;;
esac

case "${CONFIGURATION:-Debug}" in
  Release)
    cargo_profile_flag="--release"
    cargo_profile_directory="release"
    ;;
  *)
    cargo_profile_flag=""
    cargo_profile_directory="debug"
    ;;
esac

: "${DERIVED_FILE_DIR:?Xcode must provide DERIVED_FILE_DIR}"
: "${SRCROOT:?Xcode must provide SRCROOT}"

use_cargo "to build the Rust bridge"
# One Cargo target directory for every Xcode target that links the bridge
# (app, approval service, hook helper), so a clean build compiles the
# workspace once; Cargo's own lock serializes the phases when Xcode runs
# them in parallel. DERIVED_FILE_DIR would give each target its own copy.
cargo_target_directory="${OBJROOT:-$DERIVED_FILE_DIR}/cargo-target"
library_output_directory="$DERIVED_FILE_DIR/weir-rust"
library_name="libweir_rust_bridge.a"

mkdir -p "$library_output_directory"

build_arguments=(
  build
  --locked
  --package weir-rust-bridge
  --target "$rust_target"
)
if [[ -n "$cargo_profile_flag" ]]; then
  build_arguments+=("$cargo_profile_flag")
fi

cd "$SRCROOT"
CARGO_TARGET_DIR="$cargo_target_directory" "$cargo_bin" "${build_arguments[@]}"
built_library="$cargo_target_directory/$rust_target/$cargo_profile_directory/$library_name"
linked_library="$library_output_directory/$library_name"
if ! cmp -s "$built_library" "$linked_library"; then
  cp "$built_library" "$linked_library"
fi
