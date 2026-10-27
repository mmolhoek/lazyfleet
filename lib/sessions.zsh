# lazyfleet: A worktree's tmux session: creating, switching and attaching to it, and what the TUI shows about it.
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.

# Print "$1 $2" to stderr ($2 dimmed on a terminal; nothing with
# _lazyfleet_quiet) and keep it in _lazyfleet_sum, so the new session can show
# the same summary
_lazyfleet_say() {
  _lazyfleet_sum+=("$1${2:+ $2}")
  if [[ -n $_lazyfleet_quiet ]]; then :
  elif [[ -t 2 ]]; then print -ru2 -- "$1${2:+ $'\e[2m'$2$'\e[0m'}"
  else print -ru2 -- "$1${2:+ $2}"; fi
}

# Run setup command $3 for worktree $2 as the own command of session $1's first
# window (a "setup" window if the session exists), through an interactive
# $SHELL so mise, direnv and aliases are set up. Typing it into a fresh shell
# instead would answer whatever that shell asks first (like a mise enter hook)
# with our keys. The window prints lines $4.., runs the setup, then carries on
# as a normal login shell. fish can't source the (POSIX) setup script, so there
# it runs as a child sh of the interactive fish, which still has mise/direnv's
# env (not fish aliases).
_lazyfleet_setup_run() {
  local s=$1 p=$2 cmd=$3 f line run src sh=${SHELL:-/bin/sh}
  shift 3
  _lazyfleet_tmpdir || return 1
  # one per invocation: names can clash (api/feat-x and api-feat/x), and a
  # shell still waiting at a startup prompt hasn't read its script yet
  f=$(mktemp $REPLY/${s//\//-}.setup.XXXXXX) || return 1
  {
    for line; do print -r -- "printf '\\033[2m%s\\033[0m\\n' ${(qq)line}"; done
    print -r -- $cmd
  } >| $f
  # a -c command runs before the first prompt, so direnv's prompt hook hasn't
  # loaded this worktree's .envrc yet (or still has another one's): load it first
  case ${sh:t} in
    (fish) src="command -q direnv; and direnv export fish | source; /bin/sh ${(q)f}" ;;
    # `.`, not `source`: POSIX shells like dash (or /bin/sh when $SHELL is unset) lack it
    (bash|zsh) src="command -v direnv >/dev/null 2>&1 && eval \"\$(direnv export ${sh:t})\"; . ${(q)f}" ;;
    (*) src=". ${(q)f}" ;;
  esac
  run="$sh -ic ${(qq)src}; printf '\\n\\033[2m# lazyfleet: setup finished (exit %s)\\033[0m\\n' \$?; exec $sh -l"
  # tmux runs a command through its default-shell ($SHELL), which may not be POSIX
  run="/bin/sh -c ${(qq)run}"
  if _lazyfleet_tmux has-session -t "=$s" 2>/dev/null; then
    _lazyfleet_tmux new-window -t "=$s:" -n setup -c $p $run
  else
    _lazyfleet_tmux new-session -d -s $s -c $p $run && _lazyfleet_statusbranch $s
  fi
}

# Put the branch of the active pane's checkout in front of new session $1's
# status-right (a copy of the global one), unless status_branch=off. tmux runs
# the #() in the background: again every status-interval, and right away when
# the pane's directory changes. Leaves REPLY alone.
_lazyfleet_statusbranch() {
  local REPLY git='git -C #{q:pane_current_path}'
  local -a g
  _lazyfleet_setting status_branch LAZYFLEET_STATUS_BRANCH on
  [[ $REPLY == (off|no|false|0) ]] && return 0
  g=("${(@f)$(_lazyfleet_tmux show -gv status-right \; show -gv status-right-length)}")
  _lazyfleet_tmux \
    set -t "=$1:" status-right "#[bold]#($git symbolic-ref -q --short HEAD 2>/dev/null || $git rev-parse -q --short HEAD 2>/dev/null)#[nobold] $g[1]" \; \
    set -t "=$1:" status-right-length $(( ${g[2]:-40} + 40 ))
}

# REPLY=worktree path for a path, session name, branch or dir name
_lazyfleet_resolve() {
  [[ -d $1 ]] && { REPLY=${1:A}; return 0 }
  local repo e p br
  local -a repos hits
  _lazyfleet_repos; repos=($reply)
  for repo in $repos; do
    _lazyfleet_worktrees $repo
    for e in $reply; do
      p=${e%%$'\t'*}; br=${${e#*$'\t'}%$'\t'*}
      _lazyfleet_session $repo $p ${e##*$'\t'}
      [[ $1 == $REPLY || $1 == $br || $1 == ${repo:t}/$br || $1 == ${p:t} ]] && hits+=($p)
    done
  done
  hits=(${(u)hits})
  (( $#hits == 1 )) && { REPLY=$hits[1]; return 0 }
  REPLY=$#hits
  return 1
}

# Create the worktree's session (detached) if needed; REPLY=session name
_lazyfleet_ensure() {
  local p=${1:A} repo m=0
  _lazyfleet_toplevel $p || { _lazyfleet_err "not a git worktree: $p"; return 1 }
  repo=$REPLY
  [[ $p == ${repo:A} ]] && m=1
  _lazyfleet_session $repo $p $m
  _lazyfleet_tmux has-session -t "=$REPLY" 2>/dev/null ||
    { _lazyfleet_tmux new-session -d -s $REPLY -c $p && _lazyfleet_statusbranch $REPLY }
}

_lazyfleet_open_path() {
  _lazyfleet_ensure $1 || return
  _lazyfleet_attach "=$REPLY"
}

# Show window $1 ("=session:index"): select it, then attach/switch
_lazyfleet_open_window() {
  _lazyfleet_tmux select-window -t "$1" || return
  _lazyfleet_attach "${1%:*}"
}

# Switch to session $1 (inside tmux) or attach to it (outside)
_lazyfleet_attach() {
  if [[ -n $TMUX ]]; then
    _lazyfleet_tmux switch-client -t "$1"
  else
    # tmux refuses a stdin named /dev/tty (as under fzf's become), so attach
    # through the real controlling terminal device, opened read-write: the
    # server draws through the client's stdin, a read-only fd stays blank
    local t=${$(ps -o tty= -p $$ 2>/dev/null)// /}
    if [[ -c /dev/$t ]]; then
      _lazyfleet_tmux attach-session -t "$1" <>/dev/$t
    else
      _lazyfleet_tmux attach-session -t "$1"
    fi
  fi
}

# reply=("dir<TAB>name<TAB>status<TAB>id" ...): running Docker containers
# started from a dir (compose working dir or devcontainer folder). Asking
# docker takes ~0.4s, so it also refreshes a cache; -c only reads the cache.
_lazyfleet_containers() {
  local f out line
  reply=()
  _lazyfleet_tmpdir || return 1
  f=$REPLY/containers
  if [[ $1 == -c ]]; then
    [[ -r $f ]] && out=$(<$f)
  else
    (( $+commands[docker] )) &&
      out=$(docker ps --format '{{with .Label "devcontainer.local_folder"}}{{.}}{{else}}{{.Label "com.docker.compose.project.working_dir"}}{{end}}	{{.Names}}	{{.Status}}	{{.ID}}' 2>/dev/null)
    print -r -- $out >| $f.$$ && mv -f $f.$$ $f
  fi
  for line in ${(f)out}; do [[ $line == $'\t'* ]] || reply+=($line); done
}

# reply=(containers from _lazyfleet_containers [$2] that belong to dir $1)
_lazyfleet_containers_in() {
  local d=${1:A} line
  local -a mine
  _lazyfleet_containers $2
  for line in $reply; do [[ ${${line%%$'\t'*}:A} == $d ]] && mine+=($line); done
  reply=($mine)
}

# "* ↑1 ↓2" for worktree $1
_lazyfleet_wtstatus() {
  local out= ab a b
  # untracked files too, like rm's dirty check (git's ignore rules apply).
  # --no-optional-locks: a plain status rewrites the index under index.lock,
  # which makes a commit or pull running in that worktree (lazygit) fail
  [[ -n $(git -C $1 --no-optional-locks status --porcelain 2>/dev/null) ]] && out='*'
  if ab=$(git -C $1 rev-list --left-right --count 'HEAD...@{u}' 2>/dev/null); then
    a=${ab%%[[:space:]]*}; b=${ab##*[[:space:]]}
    (( a )) && out+=" ↑$a"
    (( b )) && out+=" ↓$b"
  fi
  print -rn -- ${out# }
}
