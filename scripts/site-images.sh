#!/usr/bin/env bash
# scripts/site-images.sh
# Weir — Regenerate the site's captures from demo mode: the landing page's in
# both looks, the documents' in the dark look and both languages.
#
# Usage: scripts/site-images.sh <path to the built app>

set -euo pipefail

APP_PATH="${1:?usage: scripts/site-images.sh <path to the built app>}"
CAPTURES=site/src/assets/captures

# Every image is taken before any replaces the one in the site, so a run that
# stops partway leaves no mix of old and new. Inside the repository's ignored
# `build/`, so the moves at the end stay on one volume.
mkdir -p build
STAGE="$(mktemp -d "build/site-images.XXXXXX")"
trap 'rm -rf -- "${STAGE}"' EXIT

# Every setting is given, so nothing exported in the calling shell reaches an image.
capture() {
  local out="$1"
  local look="$2"
  local language="$3"
  local layer="$4"
  local crop="$5"
  WEIR_SCREENSHOT_APP="${APP_PATH}" \
    WEIR_DEMO_APPEARANCE="${look}" \
    WEIR_DEMO_LANGUAGE="${language}" \
    WEIR_DEMO_LAYER="${layer}" \
    WEIR_DEMO_TIME="" \
    WEIR_SCREENSHOT_CROP="${crop}" \
    WEIR_SCREENSHOT_OUT="${STAGE}/${out}.png" \
    ./scripts/screenshot.sh
}

for look in dark light; do
  capture "hero-${look}" "${look}" en "" ""
  capture "needs-attention-${look}" "${look}" en needs-attention ""
  capture "all-projects-${look}" "${look}" en all-projects ""
done

# The documents' column is narrower than the window, so all but the whole
# window crop to the surface they are about.
for language in en ja; do
  capture "docs/window-${language}" dark "${language}" "" ""
  capture "docs/review-${language}" dark "${language}" review 1
  capture "docs/needs-attention-${language}" dark "${language}" approval-list 1
  capture "docs/approval-${language}" dark "${language}" approval-card 1
done

mkdir -p "${CAPTURES}/docs"
mv -f "${STAGE}"/docs/*.png "${CAPTURES}/docs/"
mv -f "${STAGE}"/*.png "${CAPTURES}/"
