#!/usr/bin/env bash
# scripts/site-images.sh
# Weir — Regenerate the site's captures from demo mode, in both looks.
#
# Usage: scripts/site-images.sh <path to the built app>

set -euo pipefail

APP_PATH="${1:?usage: scripts/site-images.sh <path to the built app>}"

capture() {
  local name="$1"
  local look="$2"
  local layer="$3"
  WEIR_SCREENSHOT_APP="${APP_PATH}" \
    WEIR_DEMO_APPEARANCE="${look}" \
    WEIR_DEMO_LAYER="${layer}" \
    WEIR_SCREENSHOT_OUT="site/src/assets/captures/${name}-${look}.png" \
    ./scripts/screenshot.sh
}

for look in dark light; do
  capture hero "${look}" ""
  capture needs-attention "${look}" needs-attention
  capture all-projects "${look}" all-projects
done
