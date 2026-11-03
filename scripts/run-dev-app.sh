#!/usr/bin/env bash
# scripts/run-dev-app.sh
# Weir — `make run`: quit this checkout's own Weir Dev, if it runs, and open it.
#
# Usage: scripts/run-dev-app.sh path/to/Weir\ Dev.app
#
# Every worktree's Debug build is "Weir Dev" with one bundle identifier, and
# several coding agents may each run their own at once. Quitting by name
# (`tell application "Weir Dev" to quit`) or opening by identifier would reach
# whichever one LaunchServices picks, so this goes by the app's path: only a
# process whose executable is inside this checkout's build is asked to quit,
# and `open -n` starts this build even while another worktree's is open.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 path/to/Weir Dev.app" >&2
  exit 2
fi
APP="$1"
if [[ ! -d "$APP" ]]; then
  echo "App not found: $APP (run 'make build' first)" >&2
  exit 1
fi
EXECUTABLE="$APP/Contents/MacOS/$(basename "$APP" .app)"

# The processes running this build's executable, by full path.
this_builds_processes() {
  ps -axo pid=,comm= | awk -v exe="$EXECUTABLE" '{ pid = $1; $1 = ""; sub(/^ /, ""); if ($0 == exe) print pid }'
}

pids=$(this_builds_processes)
if [[ -n "$pids" ]]; then
  for pid in $pids; do
    # A quit Apple event to that one process, as the Dock's Quit sends: the
    # app saves its session and asks before ending agents, as it always does.
    swift - "$pid" <<'SWIFT' >/dev/null 2>&1 || true
import AppKit
if let raw = Int32(CommandLine.arguments[1]), let app = NSRunningApplication(processIdentifier: raw) {
    _ = app.terminate()
}
SWIFT
  done
  # Long enough to save a session; the app may also be waiting on the
  # person's answer to its quit confirmation, which this does not answer.
  for _ in $(seq 1 50); do
    [[ -z "$(this_builds_processes)" ]] && break
    sleep 0.2
  done
  if [[ -n "$(this_builds_processes)" ]]; then
    echo "This checkout's Weir Dev is still running (is it asking to confirm the quit?); not opening another." >&2
    exit 1
  fi
fi

open -n "$APP"
