# lazyfleet: The message history: what lazyfleet says while the TUI runs, kept in ~/.lazyfleet_history.
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.
#
# Behind the TUI is the terminal it was started from, and whatever is printed
# there piles up: an error from a key, tmux's "[detached (from session x)]".
# While the TUI runs, those go to this file instead, a line each as
# "YYYY-MM-DD HH:MM:SS message" (the latest 1000 are kept), and the TUI shows
# the last one of its own run in its footer. Other output (git's, a prompt's)
# still goes to the terminal; where there is some, the TUI waits for a key
# (_lazyfleet_pause) and prints the errors there too, so they are read along.
#
# LAZYFLEET_TUI holds when the TUI started, in the same format. It is set
# while the TUI runs, so the commands behind its keys (which fzf starts) have
# it too; tmux is never handed it (_lazyfleet_tmux).
# Elsewhere LAZYFLEET_HISTORY names another file (the tests use that).

typeset -g _LAZYFLEET_HISTORY_MAX=1000

# this process's errors not yet printed (in the TUI; see _lazyfleet_pause)
typeset -ga _lazyfleet_errs=()

_lazyfleet_history_file() { REPLY=${LAZYFLEET_HISTORY:-$HOME/.lazyfleet_history} }

# REPLY=now, as the history writes it
_lazyfleet_history_now() { REPLY=${(%):-%D{%Y-%m-%d %H:%M:%S}} }

# Add message $* as one line: colours dropped, other control characters and
# line breaks made spaces. A message of only blanks is not added.
_lazyfleet_history_add() {
  emulate -L zsh
  setopt extended_glob
  local f msg="$*"
  local -a lines
  msg=${msg//$'\e'\[[0-9;]#[A-Za-z]/}
  msg=${${msg//[[:cntrl:]]/ }//[[:space:]]##/ }
  msg=${${msg# }% }
  [[ -n $msg ]] || return 0
  _lazyfleet_history_file; f=$REPLY
  [[ -r $f ]] && lines=(${(f)"$(<$f)"})
  _lazyfleet_history_now
  lines+=("$REPLY $msg")
  (( $#lines > _LAZYFLEET_HISTORY_MAX )) && lines=("${(@)lines[-_LAZYFLEET_HISTORY_MAX,-1]}")
  # (a file of its own per process, then moved: never half written)
  print -rl -- $lines >|$f.$$ 2>/dev/null && mv -f $f.$$ $f
}

# REPLY="HH:MM message": the last message, when it was added while this TUI
# runs (at or after LAZYFLEET_TUI). Fails otherwise.
_lazyfleet_history_last() {
  local f line
  local -a lines
  REPLY=
  [[ -n $LAZYFLEET_TUI ]] || return 1
  _lazyfleet_history_file; f=$REPLY
  [[ -r $f ]] || return 1
  lines=(${(f)"$(<$f)"})
  (( $#lines )) || return 1
  line=$lines[-1]
  # "YYYY-MM-DD HH:MM:SS" sorts as text the way it sorts in time
  [[ $line == <->-<->-<->' '<->:<->:<->' '?* && ! ${line[1,19]} < $LAZYFLEET_TUI ]] || return 1
  REPLY="${line[12,16]} ${line[21,-1]}"
}
