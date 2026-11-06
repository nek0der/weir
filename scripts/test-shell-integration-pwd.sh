#!/usr/bin/env bash
# Weir — checks the working directory that the bundled shell integration
# reports in OSC 7.
#
# For each shell installed here (zsh, bash, elvish), starts it interactively
# on a pseudo-terminal with Weir's integration loaded, in a folder whose name
# holds a newline, a space, "%", "?", "#", and Japanese, and reads back the
# last OSC 7 it wrote. The report must be a file:// URL for this
# host with no control character in it, and its percent-decoded path must be
# the folder's path, byte for byte. libghostty drops a control character
# inside an OSC string, so a raw path with a newline would reach Weir as a
# different folder.
#
# Run from the repo root:
#   scripts/test-shell-integration-pwd.sh
#
# Exits 0 on success, 1 on any failing case. A shell that is not installed is
# skipped with a note.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
INTEGRATION="${REPO_ROOT}/Weir/Resources/ghostty/shell-integration"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Resolve /var to /private/var, the path the shells see as their directory.
TMP="$(cd "$TMP" && pwd -P)"

# The folder the shells start in.
target="${TMP}/repo"$'\n'"line a b%25%c?#日本語"
mkdir -p "$target"
host="$(hostname)"

passes=0
fails=0
note() { printf '  ✓ %s\n' "$1"; passes=$((passes + 1)); }
warn() { printf '  ✗ %s\n' "$1" >&2; fails=$((fails + 1)); }

# Runs "$@" in the target folder on a pseudo-terminal, types "exit" into it,
# and leaves the terminal output in $TMP/<name>.out. Each shell reports its
# directory when its integration loads or at its first prompt, so the shell
# starts in the folder rather than reading a cd: script(1) can end the session
# at the end of its input before the shell reads a typed command.
run_on_pty() {
  local name="$1"
  shift
  # script(1) forwards its stdin to the shell and copies the shell's output
  # to its stdout. The time limit keeps a shell that never exits from
  # hanging the check.
  (cd "$target" && printf 'exit\n' |
    perl -e 'alarm shift; exec @ARGV' 20 script -q /dev/null "$@" \
      >"${TMP}/${name}.out" 2>&1) || true
}

# Checks the last OSC 7 in $TMP/<name>.out against the target folder.
check_report() {
  local name="$1"
  local result
  if result="$(python3 - "${TMP}/${name}.out" "$host" "$target" 2>&1 <<'PY'
import os, re, sys, urllib.parse

output = open(sys.argv[1], "rb").read()
host = sys.argv[2].encode()
target = os.fsencode(sys.argv[3])
reports = re.findall(rb"\x1b\]7;(.*?)(?:\x07|\x1b\\)", output, re.S)
if not reports:
    sys.exit("no OSC 7 report")
report = reports[-1]
if any(b < 0x20 or b == 0x7F for b in report):
    sys.exit(f"control character in the report: {report!r}")
prefix = b"file://" + host
if not report.startswith(prefix + b"/"):
    sys.exit(f"not a file:// URL for {host!r}: {report!r}")
path = urllib.parse.unquote_to_bytes(report[len(prefix):])
if path != target:
    sys.exit(f"decoded {path!r}, expected {target!r}")
PY
  )"; then
    note "$name reports the folder as a percent-encoded file:// URL"
  else
    warn "$name: ${result}"
  fi
}

echo "OSC 7 report of the bundled shell integration"

if command -v zsh >/dev/null 2>&1; then
  mkdir -p "${TMP}/zsh-home"
  # The integration's .zshenv loads ghostty-integration in an interactive
  # shell, the way libghostty starts zsh.
  run_on_pty zsh \
    env -i HOME="${TMP}/zsh-home" PATH="$PATH" TERM=xterm-256color \
    LANG=en_US.UTF-8 ZDOTDIR="${INTEGRATION}/zsh" \
    GHOSTTY_RESOURCES_DIR="${INTEGRATION}/.." GHOSTTY_SHELL_FEATURES=cursor \
    zsh -i
  check_report zsh
else
  echo "  - zsh is not installed; skipped"
fi

if command -v bash >/dev/null 2>&1; then
  mkdir -p "${TMP}/bash-home"
  printf 'builtin source %q\n' "${INTEGRATION}/bash/ghostty.bash" \
    >"${TMP}/bash-home/rc"
  run_on_pty bash \
    env -i HOME="${TMP}/bash-home" PATH="$PATH" TERM=xterm-256color \
    LANG=en_US.UTF-8 GHOSTTY_RESOURCES_DIR="${INTEGRATION}/.." \
    GHOSTTY_SHELL_FEATURES=cursor \
    bash --noprofile --rcfile "${TMP}/bash-home/rc" -i
  check_report bash
else
  echo "  - bash is not installed; skipped"
fi

if command -v elvish >/dev/null 2>&1; then
  mkdir -p "${TMP}/elvish-home/elvish"
  printf 'eval (slurp < %s)\n' \
    "'${INTEGRATION}/elvish/lib/ghostty-integration.elv'" \
    >"${TMP}/elvish-home/elvish/rc.elv"
  run_on_pty elvish \
    env -i HOME="${TMP}/elvish-home" PATH="$PATH" TERM=xterm-256color \
    LANG=en_US.UTF-8 XDG_CONFIG_HOME="${TMP}/elvish-home" \
    GHOSTTY_RESOURCES_DIR="${INTEGRATION}/.." GHOSTTY_SHELL_FEATURES=cursor \
    elvish
  check_report elvish
else
  echo "  - elvish is not installed; skipped"
fi

echo "${passes} passed, ${fails} failed"
[[ "$fails" -eq 0 ]]
