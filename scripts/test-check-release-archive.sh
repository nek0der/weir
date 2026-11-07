#!/usr/bin/env bash
# Weir — self-test for `check-release-archive.sh`.
#
# Builds fake .xcarchive trees that stand in for a distributable archive and
# for each way one can break, then asserts the checker's verdict. The real
# archive takes minutes to produce, so this is what keeps an edit to the
# checker from silently accepting the v0.1.5 generic-archive layout again.
#
# Run from the repo root:
#   scripts/test-check-release-archive.sh
#
# Exits 0 on success, 1 on any failing case (with a per-case diagnostic).
# Needs macOS for `plutil` and `PlistBuddy`, like the checker itself.

# The case mutations are invoked indirectly through run_case.
# shellcheck disable=SC2329

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECKER="${REPO_ROOT}/scripts/check-release-archive.sh"

if [[ ! -x "$CHECKER" ]]; then
  echo "FAIL: checker not found at $CHECKER" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passes=0
fails=0

# Writes the layout `xcodebuild archive` produced for a good Release archive
# on Xcode 26, unsigned, into the directory given as $1.
make_good_archive() {
  local archive="$1"
  local app="$archive/Products/Applications/Weir.app/Contents"
  mkdir -p "$app/MacOS" "$app/Library/LaunchAgents" "$app/Frameworks/Sparkle.framework"
  for binary in Weir AgentIntegrationService AgentIntegrationHookHelper; do
    printf '#!/bin/sh\n' > "$app/MacOS/$binary"
    chmod +x "$app/MacOS/$binary"
  done
  cp "${REPO_ROOT}/AgentIntegrationService/Resources/com.nekoder.weir.agent-integration-service.plist" \
    "$app/Library/LaunchAgents/"
  plutil -create xml1 "$archive/Info.plist"
  plutil -insert ApplicationProperties -dictionary "$archive/Info.plist"
  plutil -insert ApplicationProperties.ApplicationPath -string Applications/Weir.app \
    "$archive/Info.plist"
}

# $1 case name, $2 exit status, $3 required diagnostic lines, then the
# command that mutates the archive. Empty diagnostics mean no refusal.
run_case() {
  local name="$1" expected_status="$2" diagnostics="$3"
  shift 3
  local archive
  archive="$(mktemp -d -p "$TMP")/Weir.xcarchive"
  make_good_archive "$archive"
  "$@" "$archive"

  local output exit_status=0 matches=true diagnostic
  output="$("$CHECKER" "$archive" 2>&1)" || exit_status=$?
  while IFS= read -r diagnostic; do
    [[ -z "$diagnostic" || "$output" == *"$diagnostic"* ]] || matches=false
  done <<<"$diagnostics"
  if [[ "$exit_status" == "$expected_status" && "$matches" == true ]]; then
    printf '  ok   %s\n' "$name"
    passes=$((passes + 1))
  else
    printf '  FAIL %s (expected exit %s and diagnostics %s, got exit %s)\n%s\n' \
      "$name" "$expected_status" "$diagnostics" "$exit_status" "$output" >&2
    fails=$((fails + 1))
  fi
}

unchanged() { :; }

# What v0.1.5 shipped: tools installed beside the app, and no
# ApplicationProperties because Xcode no longer saw a single app.
generic_archive() {
  mkdir -p "$1/Products/usr/local/bin"
  printf '#!/bin/sh\n' > "$1/Products/usr/local/bin/AgentIntegrationService"
  plutil -remove ApplicationProperties "$1/Info.plist"
}
stray_product() { mkdir -p "$1/Products/usr/local/bin"; }
no_application_properties() { plutil -remove ApplicationProperties "$1/Info.plist"; }
missing_service() { rm "$1/Products/Applications/Weir.app/Contents/MacOS/AgentIntegrationService"; }
missing_hook_helper() { rm "$1/Products/Applications/Weir.app/Contents/MacOS/AgentIntegrationHookHelper"; }
missing_sparkle() { rm -r "$1/Products/Applications/Weir.app/Contents/Frameworks/Sparkle.framework"; }
missing_service_plist() {
  rm "$1/Products/Applications/Weir.app/Contents/Library/LaunchAgents/com.nekoder.weir.agent-integration-service.plist"
}
malformed_service_plist() {
  printf 'not a plist' > \
    "$1/Products/Applications/Weir.app/Contents/Library/LaunchAgents/com.nekoder.weir.agent-integration-service.plist"
}
SERVICE_PLIST_PATH="Products/Applications/Weir.app/Contents/Library/LaunchAgents/com.nekoder.weir.agent-integration-service.plist"
dev_label() { plutil -replace Label -string com.nekoder.weir.agent-integration-service.dev "$1/$SERVICE_PLIST_PATH"; }
missing_label() { plutil -remove Label "$1/$SERVICE_PLIST_PATH"; }
wrong_program() { plutil -replace BundleProgram -string Contents/MacOS/Weir "$1/$SERVICE_PLIST_PATH"; }
missing_requester() {
  /usr/libexec/PlistBuddy -c "Delete :MachServices:com.nekoder.weir.agent-integration-service.requester" \
    "$1/$SERVICE_PLIST_PATH"
}
disabled_controller() {
  /usr/libexec/PlistBuddy -c "Set :MachServices:com.nekoder.weir.agent-integration-service.controller false" \
    "$1/$SERVICE_PLIST_PATH"
}
extra_mach_service() {
  /usr/libexec/PlistBuddy -c "Add :MachServices:com.nekoder.weir.agent-integration-service.dev.requester bool true" \
    "$1/$SERVICE_PLIST_PATH"
}
dev_service_plist() {
  cp "$1/Products/Applications/Weir.app/Contents/Library/LaunchAgents/com.nekoder.weir.agent-integration-service.plist" \
    "$1/Products/Applications/Weir.app/Contents/Library/LaunchAgents/com.nekoder.weir.agent-integration-service.dev.plist"
}
missing_archive() { rm -r "$1"; }
automation_channel() {
  printf 'weir-automation-protocol/1' >> "$1/Products/Applications/Weir.app/Contents/MacOS/Weir"
}

run_case 'a distributable archive passes' 0 '' unchanged
run_case 'the v0.1.5 generic archive fails' 1 'FAIL: Info.plist has no ApplicationProperties:ApplicationPath
FAIL: Products/ holds more than' generic_archive
run_case 'a stray product beside the app fails' 1 'FAIL: Products/ holds more than' stray_product
run_case 'a missing ApplicationProperties fails' 1 'FAIL: Info.plist has no ApplicationProperties:ApplicationPath' no_application_properties
run_case 'a missing AgentIntegrationService fails' 1 'FAIL: Contents/MacOS/AgentIntegrationService is missing or not executable' missing_service
run_case 'a missing AgentIntegrationHookHelper fails' 1 'FAIL: Contents/MacOS/AgentIntegrationHookHelper is missing or not executable' missing_hook_helper
run_case 'a missing Sparkle.framework fails' 1 'FAIL: Sparkle.framework is not embedded' missing_sparkle
run_case 'a missing release service plist fails' 1 'FAIL: the release agent integration service plist is missing' missing_service_plist
run_case 'a malformed release service plist fails' 1 'FAIL: the agent integration service plist does not lint' malformed_service_plist
run_case 'a bundled development service plist fails' 1 'FAIL: the development service plist is bundled in a Release archive' dev_service_plist
run_case 'a service plist with the development label fails' 1 'FAIL: the service plist'"'"'s Label is' dev_label
run_case 'a service plist with no label fails' 1 'FAIL: the service plist'"'"'s Label is' missing_label
run_case 'a service plist naming another program fails' 1 'FAIL: the service plist'"'"'s BundleProgram is' wrong_program
run_case 'a service plist without the requester service fails' 1 'FAIL: the service plist does not publish the Mach service com.nekoder.weir.agent-integration-service.requester' missing_requester
run_case 'a service plist with the controller service off fails' 1 'FAIL: the service plist does not publish the Mach service com.nekoder.weir.agent-integration-service.controller' disabled_controller
run_case 'a service plist with an extra Mach service fails' 1 'FAIL: the service plist publishes 3 Mach services, not 2' extra_mach_service
run_case 'a missing archive fails' 1 'FAIL: archive not found at' missing_archive
run_case 'a binary with the verification channel fails' 1 'FAIL: the Debug-only verification channel is compiled into a Release binary' automation_channel

echo
if [[ $fails -eq 0 ]]; then
  echo "test-check-release-archive: $passes case(s) passed."
  exit 0
fi
echo "test-check-release-archive: $fails failure(s) of $((passes + fails)) case(s)." >&2
exit 1
