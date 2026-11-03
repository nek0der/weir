#!/usr/bin/env bash
# Weir — assert that an .xcarchive is one `exportArchive` can distribute.
#
# The release workflow is the only place that runs `archive` and
# `exportArchive`, and it runs them after the tag exists. The v0.1.5 release
# failed there: two command-line tool targets installed themselves under
# `Products/usr/local/bin`, so Xcode classed the archive as generic and
# `exportArchive` refused the developer-id method. These checks catch that
# class of failure on an unsigned archive, before a tag is ever pushed.
# Signing, notarization, and Sparkle's XPC entitlements still need the
# Developer ID certificate and stay release-time only.
#
# Usage:
#   scripts/check-release-archive.sh path/to/Weir.xcarchive
#
# Exits 0 when every check passes, 1 otherwise (each failure is printed).

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 path/to/Weir.xcarchive" >&2
  exit 2
fi

ARCHIVE="$1"
APP_RELATIVE="Applications/Weir.app"
APP="$ARCHIVE/Products/$APP_RELATIVE"
SERVICE_PLIST_DIR="$APP/Contents/Library/LaunchAgents"
SERVICE_PLIST="$SERVICE_PLIST_DIR/com.nekoder.weir.agent-integration-service.plist"
# The Release values of `AgentIntegrationConfiguration` (its `#else` block).
# The app registers the plist by name and then connects to these, so a plist
# that names others still lints and registers, and every approval then finds
# no service.
SERVICE_LABEL="com.nekoder.weir.agent-integration-service"
SERVICE_PROGRAM="Contents/MacOS/AgentIntegrationService"
SERVICE_MACH_SERVICES=(
  "com.nekoder.weir.agent-integration-service.controller"
  "com.nekoder.weir.agent-integration-service.requester"
)
DEV_SERVICE_PLIST="$SERVICE_PLIST_DIR/com.nekoder.weir.agent-integration-service.dev.plist"

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$SERVICE_PLIST" 2>/dev/null || true
}

check_service_plist() {
  local label program mach_count
  label=$(plist_value Label)
  [[ "$label" == "$SERVICE_LABEL" ]] \
    || fail "the service plist's Label is '${label}', not $SERVICE_LABEL"
  program=$(plist_value BundleProgram)
  [[ "$program" == "$SERVICE_PROGRAM" ]] \
    || fail "the service plist's BundleProgram is '${program}', not $SERVICE_PROGRAM"
  for name in "${SERVICE_MACH_SERVICES[@]}"; do
    [[ "$(plist_value "MachServices:$name")" == "true" ]] \
      || fail "the service plist does not publish the Mach service $name"
  done
  # PlistBuddy prints each entry of a dictionary as "key = value".
  mach_count=$(plist_value MachServices | grep -c ' = ' || true)
  [[ "$mach_count" -eq "${#SERVICE_MACH_SERVICES[@]}" ]] \
    || fail "the service plist publishes $mach_count Mach services, not ${#SERVICE_MACH_SERVICES[@]}"
}

if [[ ! -d "$ARCHIVE" ]]; then
  echo "FAIL: archive not found at $ARCHIVE" >&2
  exit 1
fi

# Xcode decides between an app archive and a generic one from this key. A
# generic archive offers no distribution method, which is the v0.1.5 error.
app_path=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' \
  "$ARCHIVE/Info.plist" 2>/dev/null || true)
if [[ "$app_path" != "$APP_RELATIVE" ]]; then
  fail "Info.plist has no ApplicationProperties:ApplicationPath of $APP_RELATIVE (got '${app_path}'); Xcode will treat this as a generic archive"
fi

# Anything installed next to the app (a tool without SKIP_INSTALL, a stray
# framework) is what turns the archive generic, so the product tree must hold
# the app and nothing else.
if [[ -d "$ARCHIVE/Products" ]]; then
  extra=$(cd "$ARCHIVE/Products" && find . -mindepth 1 -maxdepth 2 \
    ! -path './Applications' ! -path "./$APP_RELATIVE" | sort)
  if [[ -n "$extra" ]]; then
    fail "Products/ holds more than $APP_RELATIVE:"$'\n'"$extra"
  fi
else
  fail "Products/ is missing"
fi

if [[ ! -d "$APP" ]]; then
  fail "$APP_RELATIVE is missing from Products/"
else
  for tool in AgentIntegrationService AgentIntegrationHookHelper; do
    [[ -x "$APP/Contents/MacOS/$tool" ]] || fail "Contents/MacOS/$tool is missing or not executable"
  done
  [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] || fail "Sparkle.framework is not embedded"
  if [[ -f "$SERVICE_PLIST" ]]; then
    if plutil -lint -s "$SERVICE_PLIST"; then
      check_service_plist
    else
      fail "the agent integration service plist does not lint"
    fi
  else
    fail "the release agent integration service plist is missing"
  fi
  # The development plist registers a different label; shipping it would
  # register the Debug service in a user's session.
  [[ ! -e "$DEV_SERVICE_PLIST" ]] || fail "the development service plist is bundled in a Release archive"
  # The agent verification channel (ADR 0005) compiles only in Debug. Its
  # protocol marker and its type names appear nowhere else, so finding one
  # in a Release binary means a listener that can type into panes would ship.
  if [[ -d "$APP/Contents/MacOS" ]] \
    && grep -rlaE 'weir-automation-protocol/|AutomationServer|AutomationController' "$APP/Contents/MacOS" >/dev/null; then
    fail "the Debug-only verification channel is compiled into a Release binary"
  fi
fi

if [[ $failures -gt 0 ]]; then
  echo "check-release-archive: $failures check(s) failed for $ARCHIVE" >&2
  exit 1
fi
echo "check-release-archive: $ARCHIVE is distributable"
