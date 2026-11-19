# lazyfleet: docker compose up and down per worktree: x in the TUI, lazyfleet compose.
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.
#
# A worktree's compose containers are those whose compose working directory
# (the label com.docker.compose.project.working_dir) is the worktree: the 🐳
# mark on its row counts them (with devcontainers). Two things make worktrees
# of one repo get in each other's way:
# - a project name fixed by the compose file (name:) or COMPOSE_PROJECT_NAME:
#   then every worktree is the same project, and "up" in a second one only
#   says "Running" while the containers go on running the first one's files;
# - the same host ports (and container_name:), which make "up" fail.
# So before "up", the compose containers running from the repo's other
# worktrees are named, and on a terminal stopped first if you say so. "down"
# goes by the project names on the worktree's own containers, so it works
# whatever the compose file says now, and never stops another worktree's.

# reply=the compose command: docker's plugin, else the old docker-compose
_lazyfleet_compose_cmd() {
  reply=()
  if (( $+commands[docker] )) && docker compose version >/dev/null 2>&1; then reply=(docker compose)
  elif (( $+commands[docker-compose] )); then reply=(docker-compose)
  else _lazyfleet_err 'docker compose is not installed'; fi
}

# Succeeds when worktree $1 has a compose file (or names one in its .env)
_lazyfleet_compose_file() {
  local f
  for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do [[ -f $1/$f ]] && return 0; done
  [[ -r $1/.env ]] && grep -q '^[[:space:]]*COMPOSE_FILE=' $1/.env 2>/dev/null
}

# reply=("dir<TAB>project<TAB>container" ...): the running compose containers
_lazyfleet_compose_running() {
  local line
  reply=()
  (( $+commands[docker] )) || return 0
  for line in ${(f)"$(docker ps --filter label=com.docker.compose.project \
      --format '{{.Label "com.docker.compose.project.working_dir"}}	{{.Label "com.docker.compose.project"}}	{{.Names}}' 2>/dev/null)"}; do
    [[ $line == /*$'\t'?*$'\t'?* ]] && reply+=($line)
  done
}

# reply=(the compose projects running from dir $1, each once); $2...: the
# lines of _lazyfleet_compose_running to look in
_lazyfleet_compose_projects() {
  local d=${1:A} line
  local -aU found
  shift
  for line in "$@"; do [[ ${${line%%$'\t'*}:A} == $d ]] && found+=(${${line#*$'\t'}%%$'\t'*}); done
  reply=($found)
}

# reply=("dir<TAB>project<TAB>count" ...): compose projects running from the
# other worktrees of the repo of worktree $1
_lazyfleet_compose_others() {
  local p=${1:A} wt d proj n line
  local -a running found
  _lazyfleet_compose_running; running=($reply)
  (( $#running )) || { reply=(); return 0 }
  _lazyfleet_toplevel $p || { reply=(); return 0 }
  _lazyfleet_worktrees_raw $REPLY
  for wt in $reply; do
    d=${${wt%%$'\t'*}:A}
    [[ $d == $p ]] && continue
    _lazyfleet_compose_projects $d $running
    for proj in $reply; do
      n=0
      for line in $running; do [[ ${${line%%$'\t'*}:A} == $d && ${${line#*$'\t'}%%$'\t'*} == $proj ]] && (( n++ )); done
      found+=("$d"$'\t'"$proj"$'\t'"$n")
    done
  done
  reply=($found)
}

# Stop compose project $1 (by its name: no compose file needed). Run from /,
# so no compose file around is read.
_lazyfleet_compose_stop() {
  local -a cmd
  _lazyfleet_compose_cmd || return 1
  cmd=($reply)
  ( cd / && _lazyfleet_compose_run "compose down: $1" $cmd -p $1 down )
}

# Run compose ($2...). In the TUI its output is kept back and only shown when
# it fails (it would be left in the terminal behind the TUI): a line saying
# what runs ($1) stands in for it, wiped once it is done.
_lazyfleet_compose_run() {
  local what=$1 out rc
  shift
  [[ -n $LAZYFLEET_TUI ]] || { "$@"; return }
  print -nru2 -- "$what…"
  out=$("$@" 2>&1); rc=$?
  print -nu2 -- $'\r\e[K'
  (( rc )) && print -ru2 -- $out
  return rc
}

# lazyfleet compose up|down|toggle [worktree]
_lazyfleet_compose() {
  local sub=$1
  (( $# )) && shift
  [[ $sub == (up|down|toggle) ]] || { _lazyfleet_err 'usage: lazyfleet compose up|down|toggle [worktree]'; return 1 }
  _lazyfleet_worktree_arg "$1" 'usage: lazyfleet compose up|down|toggle [worktree]' || return 1
  _lazyfleet_compose_$sub $REPLY
}

# On a terminal, ask whether to stop what runs from the other worktrees first
_lazyfleet_compose_askstop() { [[ -t 0 ]] && _lazyfleet_ask "Stop it there first?" }

# up in worktree $1 when none of its compose containers run, else down
_lazyfleet_compose_toggle() {
  _lazyfleet_compose_running
  _lazyfleet_compose_projects $1 $reply
  if (( $#reply )); then _lazyfleet_compose_down $1; else _lazyfleet_compose_up $1; fi
}

# docker compose up -d in worktree $1. What runs from the repo's other
# worktrees is named first, and on a terminal stopped if you say so.
_lazyfleet_compose_up() {
  local p=$1 e d proj
  local -a cmd others
  _lazyfleet_compose_cmd || return 1
  cmd=($reply)
  _lazyfleet_compose_file $p || { _lazyfleet_err "no compose file in ${p/#$HOME/~}"; return 1 }
  _lazyfleet_compose_others $p; others=($reply)
  if (( $#others )); then
    print -r -- $'\e[33mWarning:\e[0m compose also runs from another worktree of this repo (the same project or ports would clash):'
    for e in $others; do
      d=${e%%$'\t'*}; proj=${${e#*$'\t'}%%$'\t'*}
      print -r -- "   ${d/#$HOME/~}: project $proj, ${e##*$'\t'} container(s)"
    done
    if _lazyfleet_compose_askstop; then
      for e in $others; do _lazyfleet_compose_stop ${${e#*$'\t'}%%$'\t'*} || return 1; done
    fi
  fi
  ( cd $p && _lazyfleet_compose_run "compose up in ${p/#$HOME/~}" $cmd up -d ) || { _lazyfleet_err "compose up failed in ${p/#$HOME/~}"; return 1 }
  _lazyfleet_history_note "compose up in ${p/#$HOME/~}"
}

# docker compose down for the compose projects running from worktree $1
_lazyfleet_compose_down() {
  local p=$1 proj rc=0
  _lazyfleet_compose_running
  _lazyfleet_compose_projects $p $reply
  (( $#reply )) || { _lazyfleet_err "no compose containers run from ${p/#$HOME/~}"; return 1 }
  for proj in $reply; do _lazyfleet_compose_stop $proj || rc=1; done
  (( rc )) && { _lazyfleet_err "compose down failed in ${p/#$HOME/~}"; return 1 }
  _lazyfleet_history_note "compose down in ${p/#$HOME/~}"
}

# x in the TUI: up or down; what went wrong stays on the screen until a key
_lazyfleet_ui_compose() { _lazyfleet_compose_toggle $1 || _lazyfleet_pause }
