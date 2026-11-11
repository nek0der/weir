#!/bin/sh
# Weir shared agent runtime helpers — invocation identity, the first
# instruction, and locating the agent, for every agent shim; and what a hook
# wrapper says when the Hook Helper is missing.

# The new session's first instruction. Weir no longer writes these
# files; an earlier build wrote it to a 0600 file and named the file in
# WEIR_INITIAL_PROMPT_FILE, and we still consume a file a restored tab
# was staged with. The text is never in an environment a later process
# inherits, nor in a shell's program text: the reader below passes it to
# the agent as its last argument. The launch Weir staged takes it: it
# renames the file to a name of its own, so of two launches one wins,
# and forgets the variable. A later launch in the same pane, whose shell still names the
# file, finds none and gets no instruction. A launch that starts no new
# session does not take it (`weir_prompt_allowed_for`): `claude
# --version` typed first must not use the instruction up, and `codex
# resume` would read it as a session id. Flags an alias adds
# (`--model`, a permission mode) do not stop it. The shim sets
# `weir_prompt_allowed` from its own arguments before adding any. Sets
# weir_initial_prompt_file to the taken file and succeeds when there
# was one. The taken file is touched, so its age counts from the take
# (`InitialPromptFile.removeOrphans`).
weir_take_initial_prompt() {
  weir_initial_prompt_file=""
  ltip_file="${WEIR_INITIAL_PROMPT_FILE:-}"
  unset WEIR_INITIAL_PROMPT_FILE
  [ -n "$ltip_file" ] || return 1
  [ "${weir_prompt_allowed:-0}" = 1 ] || return 1
  ltip_taken="$ltip_file.taken.$$"
  mv -f -- "$ltip_file" "$ltip_taken" 2>/dev/null || return 1
  touch -c -- "$ltip_taken" 2>/dev/null
  weir_initial_prompt_file="$ltip_taken"
}

# Whether the user's arguments (after $1) start a new session the first
# instruction belongs to. A launch staged by Weir has none; an alias may
# add flags (`--model opus`, `-c key=value`), which still start one. Which
# options take a value is the CLI's to know, so this is no parse but a
# list and a shape, and what neither knows keeps the instruction:
# - no argument, nor its name before `=`, nor the first two characters of
#   a bundled short option (`-rabc`), is one of the words in $1, the
#   shim's one-shot flags, resume flags, and subcommands;
# - a word that is no option comes only as the value of the option before
#   it: one first, or after another word or a `--name=value`, is a
#   subcommand or the user's own prompt;
# - there is no `--`.
# What gets through is a word after a flag that takes no value: a
# subcommand neither listed nor first (`--verbose newcmd`), which would
# take the instruction as its argument, or the user's own prompt
# (`--verbose "fix it"`), which would come with a second one.
weir_prompt_allowed_for() {
  lpa_blockers=$1
  shift
  lpa_previous=none
  for lpa_arg in "$@"; do
    case $lpa_arg in
      --) return 1 ;;
      --?*=* | -?=*) lpa_kind=assigned ;;
      -?*) lpa_kind=flag ;;
      *) lpa_kind=word ;;
    esac
    if [ "$lpa_kind" = word ]; then
      [ "$lpa_previous" = flag ] || return 1
    fi
    lpa_name=${lpa_arg%%=*}
    weir_prompt_word_in "$lpa_name" $lpa_blockers && return 1
    case $lpa_arg in
      --*) ;;
      -??*) weir_prompt_word_in "${lpa_arg%"${lpa_arg#??}"}" $lpa_blockers && return 1 ;;
    esac
    lpa_previous=$lpa_kind
  done
  return 0
}

# Whether $1 is one of the words after it.
weir_prompt_word_in() {
  lpw_word=$1
  shift
  for lpw_candidate in "$@"; do
    [ "$lpw_word" = "$lpw_candidate" ] && return 0
  done
  return 1
}

# Runs the agent with the taken instruction: reads the file, deletes it,
# and execs the agent with the text after `--`, as one argument. A script
# of its own, given to `sh -c` ahead of the agent's argv, so that inside
# tmux the text never travels on tmux's command line, which tmux limits to
# about 16 KB. The `x` keeps the instruction's own trailing newlines,
# which `$(...)` would strip. $1 is the file; $2 is 1 when a one-word
# instruction gets a trailing space: Claude's argument parser takes a lone
# word after `--` as a subcommand when one has that name (`doctor`,
# `purge`), and a space makes it no subcommand's name. Whether a word has
# a space is read in the shell's locale: in the C locale an ideographic
# space is no space, and a Japanese instruction of two words gets the
# trailing space too, which does no harm. The rest is the agent's argv.
weir_prompt_reader='lpr_file=$1; lpr_pad=$2; shift 2
lpr_text=$(cat -- "$lpr_file" 2>/dev/null; printf x); lpr_text=${lpr_text%x}
rm -f -- "$lpr_file"
[ -n "$lpr_text" ] || exec "$@"
case $lpr_text in
  *[[:space:]]*) ;;
  *) [ "$lpr_pad" = 1 ] && lpr_text="$lpr_text " ;;
esac
exec "$@" -- "$lpr_text"'

# Starts the agent inside its tmux session with this pane's environment
# and nothing else of the tmux server's. A session takes every variable it
# is not given from the server's environment, which is the environment of
# the pane whose agent started the server: another pane's `PATH`, account,
# record directories, and the person's own exports there. No list of names
# can cover the person's own, so the shim saves every exported variable
# (`weir_save_pane_environment`), and this starts from an empty environment
# and reads them back, as the agent would have them outside tmux. On top go
# the variables tmux sets for the terminal it is, measured on tmux 3.8: the
# agent draws on tmux, not on the pane. They travel as `NAME=value`
# arguments up to a `--`. The reading shell is `dash`, which wrote the
# file: it holds no read-only variable, where bash refuses a pane's `UID`,
# `EUID`, or `SHELLOPTS` and would stop there. The text is held in a
# positional argument, so no name of ours can clash with one of the pane's,
# and ends in `x` only when `cat` read it all (`y` when `cat` failed,
# whatever it printed first). The file is removed as soon as it is read,
# whether or not that worked. One that cannot be read starts nothing,
# rather than an agent with no environment, and says so for two seconds
# before tmux closes the session. $1 is the file; the rest is the agent's
# argv.
weir_hosted_env_reader='lhe_file=$1
shift
set -- -- "$@"
for lhe_name in TERM TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM TMUX TMUX_PANE; do
  eval "lhe_is_set=\${$lhe_name+set}"
  [ -n "$lhe_is_set" ] || continue
  eval "lhe_value=\${$lhe_name}"
  set -- "$lhe_name=$lhe_value" "$@"
done
exec /usr/bin/env -i /bin/dash -c "lhe_fail() {
  printf \"%s\\n\" \"Weir: the pane environment saved for this agent could not be read, so the agent did not start. Run the command again.\" >&2
  /bin/sleep 2
  exit 1
}
set -- \"\$(/bin/cat -- \"\$1\" && printf x || printf y)\" \"\$@\"
/bin/rm -f -- \"\$2\"
case \$1 in *x) ;; *) lhe_fail ;; esac
eval \"\${1%x}\" || lhe_fail
shift 2
while [ \"\$1\" != -- ]; do export \"\$1\"; shift; done
shift
exec \"\$@\"" weir-env "$lhe_file" "$@"'

# A temporary folder only this user can change: TMPDIR, or the one macOS
# gives each user, whichever is first to be a folder of ours, not a link,
# that no one else may write to. Another user who can write to the folder
# could swap the saved environment for a file of their own, which the
# session would then run. Sets weir_private_temp_dir and succeeds when
# there is one.
weir_find_private_temp_dir() {
  weir_private_temp_dir=""
  for lfpt_dir in "${TMPDIR:-}" "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"; do
    lfpt_dir="${lfpt_dir%/}"
    [ -n "$lfpt_dir" ] && [ -d "$lfpt_dir" ] && [ ! -L "$lfpt_dir" ] && [ -O "$lfpt_dir" ] || continue
    case "$(/usr/bin/stat -f %Lp "$lfpt_dir" 2>/dev/null)" in
      ?[0145][0145]) ;;
      *) continue ;;
    esac
    weir_private_temp_dir="$lfpt_dir"
    return 0
  done
  return 1
}

# Saves this pane's exported variables for `weir_hosted_env_reader`, in a
# file only this user can read (`mktemp` makes it 0600) in a folder only
# this user can change (`weir_find_private_temp_dir`). `dash` writes them,
# so `dash` can read them back: each value in single quotes, byte for byte.
# The values include the person's secrets. A session reads and removes
# its own file within moments; one whose session never ran (the server
# failed to start, the session was killed at once) is removed once it is
# a minute old, here by the next hosted launch and by Weir at its own
# launch (`HostedPaneEnvironmentFile.removeOrphans`). Sets
# weir_pane_environment_file and succeeds when the file holds them all.
weir_save_pane_environment() {
  weir_pane_environment_file=""
  [ -x /bin/dash ] && weir_find_private_temp_dir || return 1
  find "$weir_private_temp_dir" -maxdepth 1 -type f -name 'weir-hosted-env.*' -mmin +1 -exec rm -f {} + 2>/dev/null
  lspe_file=$(/usr/bin/mktemp "$weir_private_temp_dir/weir-hosted-env.XXXXXXXXXXXX" 2>/dev/null) || return 1
  if ! /bin/dash -c 'export -p' >"$lspe_file" 2>/dev/null; then
    rm -f -- "$lspe_file"
    return 1
  fi
  weir_pane_environment_file="$lspe_file"
}

# Hands off to the agent, which is every argument after the first two, inside
# a tmux session of its own when $1 is 1, with this pane's environment
# (`weir_hosted_env_reader`). $2 is 1 when a one-word instruction gets a
# trailing space (`weir_prompt_reader`). Each shim says its own; the rest is
# the same for every agent.
weir_exec_agent() {
  lea_hosts_in_tmux=$1
  lea_pad_lone_word=$2
  shift 2
  # The first instruction goes last, after `--`, as one argument whatever
  # it holds: quotes and `$(...)` reach the agent as typed. A reader in
  # front of the agent passes it, inside tmux as outside
  # (`weir_prompt_reader`).
  if command -v weir_take_initial_prompt >/dev/null 2>&1 && weir_take_initial_prompt; then
    set -- /bin/sh -c "$weir_prompt_reader" weir-prompt "$weir_initial_prompt_file" "$lea_pad_lone_word" "$@"
  fi
  [ "$lea_hosts_in_tmux" = 1 ] || exec "$@"
  # Saved last, once the shim has exported everything the agent and its
  # hooks read. Without the file the agent runs here, as with the setting
  # off: in tmux it would run with the server's environment.
  if ! weir_save_pane_environment; then
    unset WEIR_AGENT_TMUX_HOST_MODE
    exec "$@"
  fi
  # Unique per invocation. `-A` is deliberately absent: with the name
  # already taken it attaches and silently drops the command, handing
  # back the running agent instead of starting the one that was asked
  # for.
  lea_session="weir-$(printf '%s' "$WEIR_PANE_ID" | tr -cd 'A-Za-z0-9' | cut -c1-8)-$$"
  # The agent command is in "$@" and the tmux command line has to come
  # before it. We append the tmux side after it and then rotate the
  # agent command to the end, which is how a list whose values may hold
  # spaces is built in POSIX sh. More than one argument after the
  # options is what makes tmux exec our argv directly rather than pass a
  # single string to `sh -c`, so nothing here needs quoting.
  lea_count=$#
  set -- "$@" -L "${WEIR_AGENT_TMUX_SOCKET:-weir}" -f /dev/null \
    set -s escape-time 10 ";" \
    set -s default-terminal tmux-256color ";" \
    set -sa terminal-overrides ",*:RGB" ";" \
    set -g prefix None ";" \
    new-session -s "$lea_session" \
    /bin/sh -c "$weir_hosted_env_reader" weir-env "$weir_pane_environment_file"
  while [ "$lea_count" -gt 0 ]; do
    lea_arg="$1"
    shift
    set -- "$@" "$lea_arg"
    lea_count=$((lea_count - 1))
  done
  exec "$WEIR_AGENT_TMUX" "$@"
}

# Whether the user's arguments (after $1 and $2) start an agent the shim
# hosts in a tmux session of Weir's own (Settings > Advanced > tmux).
# $1 is the shim's first arguments that begin an interactive session, $2
# the flags that make any invocation a one-shot. Each shim names its own
# lists; the rule is the same for every agent, so it lives here once.
weir_should_host_in_tmux() {
  lsh_interactive=$1
  lsh_one_shots=$2
  shift 2
  [ -n "${WEIR_AGENT_TMUX:-}" ] && [ -x "${WEIR_AGENT_TMUX:-}" ] || return 1
  # Both variables come from the same place, so a missing pane id means
  # we are not in a Weir pane and have nothing to name the session for.
  [ -n "${WEIR_PANE_ID:-}" ] || return 1
  # Already inside a session: our directory is still on PATH in there,
  # so without this the shim would wrap itself without bound.
  [ -z "${TMUX:-}" ] || return 1
  # Anything written inside tmux is erased when the client leaves the
  # alternate screen, so only what we recognize as interactive is
  # wrapped. This is an allow list rather than a list of one-shots to
  # exclude because the two cannot be told apart from the shape of the
  # arguments: `codex fix` is a prompt and `codex exec` is a
  # subcommand, and a global option can precede either
  # (`codex -m gpt-5 exec ...`). Wrapping something that was going to
  # print and exit costs the user that output; declining to wrap an
  # interactive session only leaves it running the way it does today,
  # so the guesses are made in that direction.
  [ -t 0 ] && [ -t 1 ] || return 1
  for lsh_arg in "$@"; do
    weir_prompt_word_in "$lsh_arg" $lsh_one_shots && return 1
  done
  # No arguments at all is the ordinary interactive launch.
  [ "$#" -gt 0 ] || return 0
  weir_prompt_word_in "$1" $lsh_interactive
}

weir_ensure_run_id() {
  # We exec the real agent (not this shim) when handing off to tmux, so
  # every shim entry is a new invocation, including an agent's child.
  if [ -n "${WEIR_AGENT_RUN_ID:-}" ]; then
    WEIR_AGENT_PARENT_RUN_ID="$WEIR_AGENT_RUN_ID"
    export WEIR_AGENT_PARENT_RUN_ID
  else
    unset WEIR_AGENT_PARENT_RUN_ID
  fi
  WEIR_AGENT_RUN_ID=$(/usr/bin/uuidgen 2>/dev/null || true)
  WEIR_AGENT_RUN_ID=$(printf '%s' "$WEIR_AGENT_RUN_ID" | tr 'a-f' 'A-F')
  export WEIR_AGENT_RUN_ID
  # We mint the launch order here rather than inherit an enclosing agent's.
  # The signed helper supplies a monotonic clock shared across processes.
  # Source-tree fixtures and older bundles may have no helper yet.
  # WEIR_HOOK_HELPER is a test's, taken only outside an app bundle, as the
  # `weir-hook` wrappers take it.
  unset WEIR_AGENT_LAUNCH_ORDER
  lro_helper="${self_dir:-}/../../MacOS/AgentIntegrationHookHelper"
  case "${self_dir:-}" in
    *.app/Contents/Resources/*) ;;
    *) lro_helper="${WEIR_HOOK_HELPER:-$lro_helper}" ;;
  esac
  if [ -x "$lro_helper" ]; then
    lro_order=$("$lro_helper" launch-order </dev/null 2>/dev/null || true)
    case "$lro_order" in
      "" | *[!0-9]*) ;;
      *) WEIR_AGENT_LAUNCH_ORDER="$lro_order"; export WEIR_AGENT_LAUNCH_ORDER ;;
    esac
  fi
}

# The PATH without the shim's own folder `$1`, so that `command -v` finds the
# real agent rather than the shim `$2`, named `$3` on the PATH. The colon
# separates literal folder names. Sets weir_filtered_path.
weir_filter_path() {
  weir_filtered_path=""
  lfp_has_entry=0
  lfp_ifs="$IFS"
  lfp_flags="$-"
  # Field splitting must leave glob characters in folder names intact.
  set -f
  IFS=":"
  # The added `:` keeps a trailing empty entry, which field splitting would
  # drop, and `lfp_has_entry` keeps a leading one, which an empty result
  # would hide. An empty entry means the current folder, so one that is not
  # us stays.
  for lfp_entry in ${PATH:-}:; do
    [ "$lfp_entry" = "$1" ] && continue
    # A folder is spelled many ways (a link to it, a trailing slash, a
    # relative or empty entry), and another Weir's shim would look for us in
    # turn, so we go by what an entry holds: a shim folder's mark, or this
    # very file under another name.
    [ -e "${lfp_entry:-.}/weir-hook" ] && continue
    [ "${lfp_entry:-.}/$3" -ef "$2" ] && continue
    if [ "$lfp_has_entry" = 0 ]; then
      weir_filtered_path="$lfp_entry"
      lfp_has_entry=1
    else
      weir_filtered_path="$weir_filtered_path:$lfp_entry"
    fi
  done
  IFS="$lfp_ifs"
  case "$lfp_flags" in
    *f*) ;;
    *) set +f ;;
  esac
}

# The paths a known location names, one a line. A `/*/` stands for each
# folder there, newest version first (`sort -V`: v22.3.0 before v18.20.0,
# which a plain sort would reverse); only the star is a pattern, so a home
# folder holding `[`, `?` or `*` is taken as written.
weir_expand_location() {
  case "$1" in
    */\*/*)
      lel_parent="${1%%/\*/*}"
      lel_rest="${1#*/\*/}"
      for lel_dir in "$lel_parent"/*/; do
        [ -d "$lel_dir" ] || continue
        lel_dir="${lel_dir%/}"
        printf '%s\n' "${lel_dir##*/}"
      done | sort -r -V | while IFS= read -r lel_name; do
        printf '%s\n' "$lel_parent/$lel_name/$lel_rest"
      done
      ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# The first executable file other than `$2` (the shim itself, under whatever
# name) and outside a Weir shim folder, at one of
# the known locations in `$1`, one a line: the agent catalog's list for
# this agent (`AgentCatalog.knownLocationsEnvironment`), which the new
# workspace sheet searched before it offered the agent. A folder named
# like the agent is passed over, as the catalog passes it over. Sets
# weir_known_agent and succeeds when there is one.
weir_find_known_agent() {
  weir_known_agent=""
  [ -n "${1:-}" ] || return 1
  while IFS= read -r lfka_location; do
    [ -n "$lfka_location" ] || continue
    while IFS= read -r lfka_candidate; do
      if [ -f "$lfka_candidate" ] && [ -x "$lfka_candidate" ] && [ ! "$lfka_candidate" -ef "$2" ] &&
        [ ! -e "${lfka_candidate%/*}/weir-hook" ]; then
        weir_known_agent="$lfka_candidate"
        return 0
      fi
    done <<LFKA_CANDIDATES
$(weir_expand_location "$lfka_location")
LFKA_CANDIDATES
  done <<LFKA_LOCATIONS
$1
LFKA_LOCATIONS
  return 1
}

# For agent `$1`, which the shim found off the PATH (what the new
# workspace sheet found, or a known location; one found on the PATH runs
# as the person's terminal would run it, and the shim does not call this):
# its folder goes at the end of PATH, for what the agent starts by name
# from beside it, while everything else it runs still gets the person's
# own node and tools first. Then `weir_node_beside`. Succeeds, with
# weir_agent_node set, when there is such a node.
weir_add_agent_folder() {
  PATH="${PATH:+$PATH:}$(dirname -- "$1")"
  export PATH
  weir_node_beside "$1"
}

# The `node` beside `$1` when `$1` is a script that asks `env` for one:
# what npm installs under an nvm version, whose node is the one in that
# folder. Started on it directly, it runs on the node it was installed
# with even when the PATH has another. Sets weir_agent_node and
# succeeds when there is one. Only the first bytes are read: a native
# agent is a large binary.
weir_node_beside() {
  weir_agent_node=""
  lnb_node="$(dirname -- "$1")/node"
  [ -f "$lnb_node" ] && [ -x "$lnb_node" ] || return 1
  lnb_first_line=$(head -c 128 -- "$1" 2>/dev/null | tr -d '\000' | head -n 1)
  case "$lnb_first_line" in
    '#!'*'env node' | '#!'*'env node '*) weir_agent_node="$lnb_node" ;;
    *) return 1 ;;
  esac
}

# Said by a hook wrapper that finds no Hook Helper at $1, and exits. The
# helper is the only receiver, so without it nothing of the run is recorded
# and the changes panel, unread turns, and Restore Code go empty: the
# person has to hear of it. Both providers show a failing hook's stderr and
# go on (only exit 2 blocks), and the system log keeps the line beside the
# app's own entries.
weir_hook_helper_missing() {
  lhhm_message="Weir: the Hook Helper is missing at $1, so this agent's turns are not recorded. Reinstall Weir."
  printf '%s\n' "$lhhm_message" >&2
  /usr/bin/logger -t com.nekoder.weir.hook -p user.err "$lhhm_message" 2>/dev/null || :
  exit 1
}
