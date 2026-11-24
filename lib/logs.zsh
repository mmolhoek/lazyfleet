# lazyfleet: The logs of what runs from a worktree: l in the TUI, lazyfleet logs.
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.
#
# What runs from a worktree is what its 🐳 mark counts: its compose projects
# (their services' logs together, as "docker compose logs" shows them) and
# other containers, such as a devcontainer. With more than one, you pick.
# The logs are shown in less, following (+F): ctrl-c stops following, so you
# can scroll and search, F follows again, q quits. docker writes them to a
# file of its own, and is stopped once less quits.

typeset -g _LAZYFLEET_LOGS_TAIL=200

# reply=("kind<TAB>id<TAB>label" ...): what runs from worktree $1, kind
# compose (id: the project) or container (id: its name)
_lazyfleet_logs_targets() {
  local p=${1:A} proj line n
  local -a running found names
  _lazyfleet_compose_running; running=($reply)
  _lazyfleet_compose_projects $p $running
  for proj in $reply; do
    n=0
    for line in $running; do
      [[ ${${line%%$'\t'*}:A} == $p && ${${line#*$'\t'}%%$'\t'*} == $proj ]] || continue
      (( n++ )); names+=(${line##*$'\t'})
    done
    found+=("compose"$'\t'"$proj"$'\t'"compose project $proj ($n container${${n:#1}:+s})")
  done
  _lazyfleet_containers_in $p
  for line in $reply; do
    line=${${line#*$'\t'}%%$'\t'*}
    (( ${names[(Ie)$line]} )) || found+=("container"$'\t'"$line"$'\t'"container $line")
  done
  reply=($found)
}

# reply=(the command that follows the logs of target $1 (a line of
# _lazyfleet_logs_targets), from their last lines). With -n <lines> first:
# only that many of the last lines, not following.
_lazyfleet_logs_cmd() {
  local -a how=(--follow --tail $_LAZYFLEET_LOGS_TAIL)
  [[ $1 == -n ]] && { how=(--tail $2); shift 2 }
  local kind=${1%%$'\t'*} id=${${1#*$'\t'}%%$'\t'*}
  if [[ $kind == compose ]]; then
    _lazyfleet_compose_cmd || return 1
    reply+=(-p $id logs $how)
  else
    reply=(docker logs $how $id)
  fi
}

# Print the latest $1 lines that command $2... (a _lazyfleet_logs_cmd -n)
# gives. compose gives that many per service, one service after the other:
# asked for their times, its lines are put in order of them, the last kept,
# and the times taken out again.
_lazyfleet_logs_latest() {
  emulate -L zsh
  setopt extended_glob
  local n=$1 line t=$'\t'
  local -a lines
  shift
  if [[ $1 != docker-compose && $2 != compose ]]; then
    ( cd / && "$@" 2>&1 ) | tail -n $n
    return
  fi
  # "api-1  | 2026-11-24T10:14:06.0013Z text" → "<time><TAB>api-1  | text",
  # sorted, and the time cut off again
  lines=("${(@f)$( cd / && "$@" --timestamps 2>&1 )}")
  lines=("${(@)lines/(#b)(*)\| ([0-9-]##T[0-9:.]##Z) /$match[2]$t$match[1]| }")
  lines=("${(@o)lines}")
  # (only when there are more: zsh gives nothing for -n past the start)
  (( $#lines > n )) && lines=("${(@)lines[-n,-1]}")
  for line in $lines; do print -r -- ${line#*$t}; done
}

# The Details pane of worktree $2 while containers ($4 of them) run from it:
# the lines $3 (its session), the containers in one line, its pull request,
# then as many of their latest log lines as fit. With -f first: redrawn when
# they change (a look a second), until fzf stops this for another row. Of
# several things running, the first (l picks). Fails when nothing runs (the
# 🐳 count was cached): the git details are shown then.
_lazyfleet_preview_logs() {
  local follow= p head n out last top pr
  local -a targets cmd
  [[ $1 == -f ]] && { follow=1; shift }
  p=$1 head=$2
  _lazyfleet_logs_targets $p; targets=($reply)
  (( $#targets )) || return 1
  top=$'\e[36m🐳 '$3$' running\e[0m  \e[2m(l: all their logs, to scroll and search)\e[0m'
  pr=$(_lazyfleet_pr_preview $p)
  top+=$pr$'\n\n\e[1m'${targets[1]##*$'\t'}$'\e[0m'
  (( $#targets > 1 )) && top+=$'  \e[2m(1 of '$#targets$': l picks)\e[0m'
  # what is left of the pane's height, under all that
  n=$(( ${FZF_PREVIEW_LINES:-40} - ${#${(f)head}} - ${#${(f)top}} ))
  (( n < 5 )) && n=5
  _lazyfleet_logs_cmd -n $n $targets[1] || return 1
  cmd=($reply)
  out=$(_lazyfleet_logs_latest $n $cmd)
  print -r -- $head; print -r -- $top; print -r -- $out
  [[ -n $follow ]] || return 0
  zmodload zsh/zselect
  last=$out
  # no fork per tick for the wait: zselect -t sleeps (in 1/100 s)
  while zselect -t 100 || :; out=$(_lazyfleet_logs_latest $n $cmd); do
    [[ $out == $last ]] && continue
    last=$out
    print -rn -- $'\e[2J'; print -r -- $head; print -r -- $top; print -r -- $out
  done
}

# REPLY=the target to show, of $@ (lines of _lazyfleet_logs_targets): the only
# one, or the one picked. Fails when there is none, or several off a terminal.
_lazyfleet_logs_choose() {
  local out i=0 t
  local -a lines
  (( $# )) || return 1
  if (( $# == 1 )); then REPLY=$1; return 0; fi
  [[ -t 0 ]] || return 1
  for t in "$@"; do lines+=("$(( ++i ))"$'\t'"${t##*$'\t'}"); done
  out=$(print -rl -- $lines | fzf --layout reverse --style full --no-sort \
    --delimiter $'\t' --with-nth 2 --border-label ' Logs of ' --header 'enter show   esc cancel') || return 1
  REPLY=${@[${out%%$'\t'*}]}
}

# Show the logs that command $@ follows. In less, on a terminal: the command
# writes to a file, out of reach of ctrl-c (which only less is to act on),
# and is stopped when less quits. Elsewhere, or without less, straight out: ctrl-c
# ends them. (Run from /: compose needs no compose file for a project name.)
_lazyfleet_logs_show() {
  setopt local_options local_traps
  local f pid
  if [[ ! -t 0 || ! -t 1 ]] || (( ! $+commands[less] )); then
    ( cd / && "$@" )
    return 0
  fi
  _lazyfleet_tmpdir || return 1
  f=$REPLY/logs.$$
  : >| $f
  # a process group of its own (monitor), so the terminal's ctrl-c, meant
  # for less, never reaches it: compose would stop on it, ignored or not
  setopt monitor
  ( cd / && exec "$@" ) >>$f 2>&1 &
  pid=$!
  unsetopt monitor
  # (caught, not ignored: less is to get ctrl-c, and this shell is not to die
  # of it, leaving docker behind)
  trap : INT
  _lazyfleet_less_waits
  LESS=$REPLY less +F $f
  kill -- -$pid 2>/dev/null || kill $pid 2>/dev/null
  wait $pid 2>/dev/null
  rm -f $f
  return 0
}

# lazyfleet logs [worktree]
_lazyfleet_logs() {
  local p
  local -a targets
  _lazyfleet_worktree_arg "$1" 'usage: lazyfleet logs [worktree]' || return 1
  p=$REPLY
  _lazyfleet_logs_targets $p; targets=($reply)
  (( $#targets )) || { _lazyfleet_err "no containers run from ${p/#$HOME/~}"; return 1 }
  if (( $#targets > 1 )) && [[ ! -t 0 ]]; then
    _lazyfleet_err "several run from ${p/#$HOME/~} (pick one on a terminal): ${(j:, :)${(@)targets##*$'\t'}}"
    return 1
  fi
  # (esc in the pick: nothing to say)
  _lazyfleet_logs_choose $targets || return 0
  _lazyfleet_logs_cmd $REPLY || return 1
  _lazyfleet_logs_show $reply
}

