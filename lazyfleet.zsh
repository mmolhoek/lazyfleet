# lazyfleet — a minimal Supacode: git worktrees, each with its own tmux session.
# Source this file from .zshrc, then run `lazyfleet` (TUI) or `lazyfleet help`.

typeset -g LAZYFLEET_DIR=${${(%):-%x}:A:h}

# used throughout the parts below
zmodload -F zsh/datetime p:EPOCHSECONDS
autoload -Uz is-at-least

# The code is in lib/, one part per concern:
#   core      tmux, temp files, the repo registry, worktrees
#   config    settings and per-repo config
#   sessions  a worktree's tmux session
#   agents    Claude Code / Copilot CLI / omp in tmux panes, and their hooks
#   pr        pull request and CI marks
#   stack     stacked branches: parents, marks, restack
#   rows      what the TUI lists and previews
#   commands  add, forget, ls, new, open, rm, pull, config
#   tui       the fzf driver, its keys and prompts
#   help      help and version
#   update    the check for a newer release
#   doctor    lazyfleet doctor
#   prune     lazyfleet prune
source $LAZYFLEET_DIR/lib/core.zsh
source $LAZYFLEET_DIR/lib/config.zsh
source $LAZYFLEET_DIR/lib/sessions.zsh
source $LAZYFLEET_DIR/lib/agents.zsh
source $LAZYFLEET_DIR/lib/pr.zsh
source $LAZYFLEET_DIR/lib/stack.zsh
source $LAZYFLEET_DIR/lib/rows.zsh
source $LAZYFLEET_DIR/lib/commands.zsh
source $LAZYFLEET_DIR/lib/tui.zsh
source $LAZYFLEET_DIR/lib/update.zsh
source $LAZYFLEET_DIR/lib/help.zsh
source $LAZYFLEET_DIR/lib/doctor.zsh
source $LAZYFLEET_DIR/lib/prune.zsh

# The command itself always runs bin/lazyfleet, which loads this file from
# disk: a shell that sourced an older version would otherwise keep running it
lazyfleet() { $LAZYFLEET_DIR/bin/lazyfleet "$@" }

_lazyfleet_main() {
  emulate -L zsh
  local cmd=$1
  (( $# )) && shift
  case $cmd in
    ('') _lazyfleet_ui_checked ;;
    (add|forget|new|open|rm|pull|prune|ls|config|update|status|hooks|doctor|stack) _lazyfleet_$cmd "$@" ;;
    (windows) _lazyfleet_ui_checked -w ;;
    (repos) _lazyfleet_repos; print -rl -- $reply ;;
    (help|-h|--help) _lazyfleet_help ;;
    (version|-V|--version) _lazyfleet_versioncmd ;;
    (_*) _lazyfleet$cmd "$@" ;;
    (*) _lazyfleet_err "unknown command: $cmd"; _lazyfleet_help >&2; return 1 ;;
  esac
}

# Completion. After compinit, autoload by absolute path and keep our dir off
# fpath: an exported FPATH leaks into every session's shell, where compinit
# would audit (and possibly reject) this directory.
if (( $+functions[compdef] )); then
  fpath=(${fpath:#$LAZYFLEET_DIR})
  autoload -Uz $LAZYFLEET_DIR/_lazyfleet
  compdef _lazyfleet lazyfleet
else
  fpath+=($LAZYFLEET_DIR)
fi
