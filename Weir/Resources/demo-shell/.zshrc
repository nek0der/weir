# Weir demo-shell/.zshrc
# The startup file of a demo pane's shell (`DemoFixture.shellEnvironment`),
# read in place of the contributor's own: the scenes are typed into this
# shell, and the contributor's history file would keep every line, while
# their prompt and plugins would make each capture differ. The system's
# files still run, so the shell keeps its usual keys; we undo the history
# file /etc/zshrc names, and any the launching environment exported.
builtin unset HISTFILE
SAVEHIST=0

# The prompt until the scene sets its own, never the contributor's user and
# host, which /etc/zshrc puts in it.
PROMPT='demo@weir %1~ %% '

# Ghostty's zsh shell integration, which reports the pane's folder (OSC 7)
# that the pane header and the capture script read. ZDOTDIR pointing here
# takes the place of libghostty's own injection, so we load it ourselves.
if [[ -o interactive && -n "$GHOSTTY_RESOURCES_DIR" ]]; then
  _weir_gi="$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
  if [[ -r "$_weir_gi" ]]; then
    builtin autoload -Uz -- "$_weir_gi"
    ghostty-integration
    builtin unfunction -- ghostty-integration 2>/dev/null
  fi
  builtin unset _weir_gi
fi
