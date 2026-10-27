# lazyfleet — a minimal Supacode: git worktrees, each with its own tmux session.
# Source this file from .zshrc, then run `lazyfleet` (TUI) or `lazyfleet help`.

typeset -g LAZYFLEET_DIR=${${(%):-%x}:A:h}
# keys that type into the find input instead while it's shown
typeset -g _LAZYFLEET_LETTERS='j,k,n,d,p,e,g,o,r,a,w,c,C,R,q,/'
typeset -g _LAZYFLEET_FOOTER_WT=$'↵ open  (n)ew worktree  (a)dd project
(d)elete  (p)ull  (e)ditor  (g) lazygit  (o) PR
(w)indows  ⇥ repos  / find
(c) project config  (C) global settings
(r)eload  (q)uit'
typeset -g _LAZYFLEET_FOOTER_REPO=$'↵ worktrees  (n)ew worktree  (a)dd project
(d) forget  ⇥ windows  / find
(c) project config  (C) global settings
(r)eload  (q)uit'
typeset -g _LAZYFLEET_FOOTER_WIN=$'↵ switch  (d) kill
⇥ views  / find
(r)eload  (q)uit
(C) global settings'
# list/Details split: the Windows view is mostly preview
typeset -g _LAZYFLEET_PW='right,50%' _LAZYFLEET_PW_WIN='right,70%'

# --- plumbing ---------------------------------------------------------------

# A tmux server keeps the environment it started with and hands it to every
# session, so never pass it an exported FPATH containing our dir: compinit in
# each session's shell would flag the dir as insecure.
_lazyfleet_tmux() {
  if [[ ${(t)FPATH} == *export* ]]; then
    FPATH=${(j.:.)${fpath:#$LAZYFLEET_DIR}} command ${=LAZYFLEET_TMUX:-tmux} "$@"
  else
    command ${=LAZYFLEET_TMUX:-tmux} "$@"
  fi
}

_lazyfleet_err() { print -ru2 -- "lazyfleet: $*"; return 1 }

# REPLY=our private dir for setup scripts, caches and temp files. Its name is
# predictable (shared /tmp when TMPDIR is unset), so refuse one that another
# user could have planted: a symlink, or not ours. Ours gets mode 700.
_lazyfleet_tmpdir() {
  REPLY=${TMPDIR:-/tmp}/lazyfleet-$UID
  mkdir -p -m 700 $REPLY 2>/dev/null
  if [[ -L $REPLY || ! -d $REPLY || ! -O $REPLY ]]; then
    _lazyfleet_err "unsafe temp dir $REPLY (a symlink, or not owned by you) — remove it or set TMPDIR"
    return 1
  fi
  chmod 700 $REPLY
}

# (into a local: a bare read would overwrite the caller's REPLY)
_lazyfleet_pause() { local k; print -n "${1:-press any key} "; read -sk1 k </dev/tty; print }

_lazyfleet_regfile() { REPLY=${XDG_CONFIG_HOME:-$HOME/.config}/lazyfleet/repos }

# Sort reply by the key that function $1 puts in REPLY for each element
# (case-insensitive)
_lazyfleet_sortby() {
  local e
  local -a keyed
  for e in $reply; do $1 $e; keyed+=("${REPLY:l}"$'\0'"$e"); done
  reply=(${${(o)keyed}#*$'\0'})
}
_lazyfleet_key_name() { REPLY=${1:t} }
_lazyfleet_key_branch() { REPLY=${${1#*$'\t'}%$'\t'*} }

# reply=(registered repo paths, by name)
_lazyfleet_repos() {
  _lazyfleet_regfile
  reply=()
  [[ -r $REPLY ]] && reply=(${(f)"$(<$REPLY)"})
  _lazyfleet_sortby _lazyfleet_key_name
}

# REPLY=main worktree of the repo containing $1 (default $PWD)
_lazyfleet_toplevel() {
  local d=${${1:-$PWD}:A} gd common
  # fast path (no fork) for worktree roots
  if [[ -d $d/.git ]]; then
    REPLY=$d; return 0
  elif [[ -f $d/.git ]]; then
    gd=$(<$d/.git); gd=${gd#gitdir: }
    [[ $gd == /* ]] || gd=${d}/$gd
    [[ $gd == */.git/worktrees/* ]] && { REPLY=${gd:A}; REPLY=${REPLY%/.git/worktrees/*}; return 0 }
  fi
  common=$(git -C $d rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [[ ${common:t} == .git ]] && { REPLY=${common:h}; return 0 }
  # metadata kept elsewhere (a submodule, git init --separate-git-dir): the
  # checkout is core.worktree if set (submodules), or $d if it isn't a linked
  # worktree; otherwise git doesn't record where the main checkout is
  if [[ -n $(git --git-dir=$common config core.worktree 2>/dev/null) ]]; then
    REPLY=$(git --git-dir=$common rev-parse --show-toplevel 2>/dev/null)
  elif [[ $(git -C $d rev-parse --path-format=absolute --git-dir 2>/dev/null) == $common ]]; then
    REPLY=$(git -C $d rev-parse --show-toplevel 2>/dev/null)
  else
    REPLY=
  fi
  [[ -n $REPLY ]]
}

# REPLY=registered repo matching a name or path
_lazyfleet_find_repo() {
  local r
  _lazyfleet_repos
  for r in $reply; do
    [[ ${r:t} == $1 || $r == ${1:A} ]] && { REPLY=$r; return 0 }
  done
  return 1
}

# REPLY=branch name from a HEAD file
_lazyfleet_head() {
  local h=$(<$1)
  [[ $h == 'ref: refs/heads/'* ]] && REPLY=${h#ref: refs/heads/} || REPLY='(detached)'
}

# reply=("path<TAB>branch<TAB>ismain" ...) for repo $1, by branch
_lazyfleet_worktrees() {
  _lazyfleet_worktrees_raw $1
  _lazyfleet_sortby _lazyfleet_key_branch
}

_lazyfleet_worktrees_raw() {
  local g=$1/.git d wt line br m skip i=0
  reply=()
  if [[ -d $g ]]; then
    # read .git directly: no fork
    _lazyfleet_head $g/HEAD; reply+=("$1"$'\t'"$REPLY"$'\t'1)
    for d in $g/worktrees/*(N/); do
      [[ -r $d/gitdir ]] || continue
      wt=$(<$d/gitdir); wt=${wt%/.git}
      [[ $wt == /* ]] || wt=${${d}/$wt:A}
      [[ -d $wt ]] || continue
      _lazyfleet_head $d/HEAD; reply+=("$wt"$'\t'"$REPLY"$'\t'0)
    done
    return
  fi
  for line in ${(f)"$(git -C $1 worktree list --porcelain 2>/dev/null)"} 'worktree '; do
    case $line in
      ('worktree '*)
        [[ -n $wt && -z $skip ]] && reply+=("$wt"$'\t'"$br"$'\t'"$m")
        wt=${line#worktree }; br='(detached)'; skip=; m=$(( i++ == 0 )) ;;
      ('branch '*) br=${line#branch refs/heads/} ;;
      (bare|prunable*) skip=1 ;;
    esac
  done
}

# REPLY=tmux session name for worktree $2 of repo $1 ($3=1 if main worktree)
_lazyfleet_session() {
  REPLY=${1:t}
  [[ $3 == 1 ]] || REPLY+=/${2:t}
  REPLY=${REPLY//[.:]/-}
}

# REPLY=value of key $2 in file $1. Lines indented deeper than the key= line
# continue the value (minus the first one's indent). With repo $3, only
# [sections] naming that repo (by name or path) count; with -, only lines
# before any section.
_lazyfleet_conf_read() {
  local key=$2 repo=$3 line lead text sect ind on=1 hit= kind
  local -a val
  [[ -n $repo && $repo != - ]] && on=
  for line in "${(@f)$(<$1)}"; do
    lead=${line%%[^[:space:]]*}; text=${line#$lead}
    if [[ -n $hit ]]; then
      if [[ -z $text ]] || (( $#lead > kind )); then
        [[ -z $ind && -n $text ]] && ind=$lead
        val+=("${line#$ind}")
        continue
      fi
      break
    fi
    if [[ -n $repo && $text == '['*']' ]]; then
      typeset -g _lazyfleet_sect=${${text#\[}%\]}
      sect=${${_lazyfleet_sect}%/}; sect=${sect/#\~/$HOME}
      [[ $sect == ${repo:t} || ( $sect == */* && ${sect:A} == ${repo:A} ) ]] && on=1 || on=
    elif [[ -n $on && $text == $key=* ]]; then
      hit=1; kind=$#lead; val=("${text#$key=}")
    fi
  done
  [[ -n $hit ]] || return 1
  # "key=" with the value on the next lines; trailing blank lines
  [[ -z $val[1] ]] && (( $#val > 1 )) && shift val
  while (( $#val > 1 )) && [[ -z $val[-1] ]]; do val[-1]=(); done
  REPLY=${(F)val}
}

# REPLY=value of key $1 for worktree $2 of repo $3, from the first of:
# ~/.config/lazyfleet/projects/<repo>.conf, the repo's [section] in
# ~/.config/lazyfleet/config (older layout), .lazyfleet in the worktree, then
# in the repo. _lazyfleet_from says which one it was.
_lazyfleet_conf() {
  local f
  typeset -g _lazyfleet_from=
  _lazyfleet_projconf $3; f=$REPLY
  if [[ -r $f ]] && _lazyfleet_conf_read $f $1; then
    _lazyfleet_from="${f/#$HOME/~}"
    return 0
  fi
  _lazyfleet_regfile; f=${REPLY:h}/config
  if [[ -r $f ]] && _lazyfleet_conf_read $f $1 $3; then
    _lazyfleet_from="${f/#$HOME/~} [$_lazyfleet_sect]"
    return 0
  fi
  for f in $2/.lazyfleet $3/.lazyfleet; do
    if [[ -r $f ]] && _lazyfleet_conf_read $f $1; then
      [[ $f == $2/* ]] && _lazyfleet_from=.lazyfleet || _lazyfleet_from="${f/#$HOME/~}"
      return 0
    fi
  done
  REPLY=
  return 1
}

# REPLY=path of repo $1's own config file
_lazyfleet_projconf() {
  _lazyfleet_regfile; REPLY=${REPLY:h}/projects/${1:t}.conf
}

# REPLY=global setting $1: $2 (an env var) if set, else the top of
# ~/.config/lazyfleet/config (before any [section]), else default $3
_lazyfleet_setting() {
  local f
  [[ -n ${(P)2} ]] && { REPLY=${(P)2}; return }
  _lazyfleet_regfile; f=${REPLY:h}/config
  [[ -r $f ]] && _lazyfleet_conf_read $f $1 - && [[ -n $REPLY ]] && return
  REPLY=$3
}

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

# --- coding agents ----------------------------------------------------------
# Claude Code and GitHub Copilot CLI sessions running in tmux panes, found by
# looking at the processes below each pane's shell. This reads command lines,
# so it is a heuristic: it knows the usual ways each tool is started.

# The tools, in the order their marks show, with each one's mark and colour
typeset -ga _LAZYFLEET_AGENT_KINDS=(claude copilot omp)
typeset -gA _LAZYFLEET_AGENT_ICON=(claude ✻ copilot ✦ omp π)
typeset -gA _LAZYFLEET_AGENT_COLOR=(claude $'\e[38;5;208m' copilot $'\e[35m' omp $'\e[36m')

# REPLY=claude, copilot or omp if command line $1 is one of those tools, else empty
_lazyfleet_agent_kind() {
  emulate -L zsh
  local -a w
  local x a
  w=(${(z)1})
  REPLY=
  case ${w[1]:t} in
    (claude) REPLY=claude ;;
    (copilot) REPLY=copilot ;;
    (omp) REPLY=omp ;;
    # the native installer runs a versioned binary: .../claude/versions/2.0.1
    (<->.<->.<->) [[ ${w[1]} == */claude/* ]] && REPLY=claude ;;
    (node|bun|deno)
      for x in ${w[2,-1]}; do [[ $x == -* ]] || { a=$x; break }; done
      case $a in
        (*/@anthropic-ai/claude-code/*|*/claude-code/*|*/bin/claude) REPLY=claude ;;
        (*/@github/copilot/*|*/bin/copilot) REPLY=copilot ;;
        (*/@oh-my-pi/*|*/bin/omp) REPLY=omp ;;
      esac ;;
    (gh) [[ ${w[2]} == copilot ]] && REPLY=copilot ;;
  esac
  [[ -n $REPLY ]]
}

# Where the hook script (bin/lazyfleet-hook) keeps what each agent is doing
_lazyfleet_agent_dir() { REPLY=${LAZYFLEET_AGENT_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/lazyfleet/agents} }

# The file name part that identifies a pane: its tmux server's socket plus its
# id, with everything but letters and digits turned into "_" (as the hook does)
_lazyfleet_agent_key() { local s=$1$2; REPLY=${s//[^A-Za-z0-9]/_} }

# REPLY=what an agent is doing: working, waiting, done, idle, or empty when
# unknown. $1 kind, $2 tmux socket, $3 pane id. This is the hook's record, and
# for Claude Code the screen has the last word on "working": a turn that was
# interrupted with Esc never runs the hook that ends it, and a session whose
# hooks are not installed has no record at all.
_lazyfleet_agent_state() {
  emulate -L zsh
  local kind=$1 st= ts file busy=
  REPLY=
  [[ -n $3 ]] || return 0
  _lazyfleet_agent_dir; file=$REPLY
  _lazyfleet_agent_key $2 $3; file=$file/$kind.$REPLY
  [[ -r $file ]] && read -r st ts <$file
  [[ $st == (working|waiting|done|idle) ]] || st=
  if [[ $kind == claude && ( -z $st || $st == working ) ]]; then
    _lazyfleet_tmux capture-pane -p -t $3 2>/dev/null | tail -n 15 | grep -qi 'esc to interrupt' && busy=1
    if [[ -n $busy ]]; then st=working
    elif [[ $st == working ]]; then st=idle
    fi
  fi
  REPLY=$st
}

# reply=("session<TAB>window<TAB>claude|copilot|omp" ...): one entry per tmux pane
# that has such a tool running below its shell (or as its shell). With -d each
# entry goes on with "<TAB>state<TAB>pane id<TAB>visible" (visible is 1 when
# someone is looking at the pane right now), and the hook's records of agents
# that have stopped are removed.
_lazyfleet_agents() {
  emulate -L zsh
  local sep='@@lf@@' line pid ppid args p n out detail= sock state vis dir rec
  local -a f live
  local -A parent kinds panes seen
  [[ $1 == -d ]] && detail=1
  reply=()
  (( $+commands[ps] )) || return 0
  # tmux 3.4 turns tabs in -F output into "_", so split on a printable separator
  out=$(_lazyfleet_tmux list-panes -a -F "#{pane_pid}${sep}#{session_name}${sep}#{window_index}${sep}#{pane_id}${sep}#{socket_path}${sep}#{session_attached}#{window_active}#{pane_active}" 2>/dev/null) || return 0
  for line in ${(f)out}; do
    line=${line//$sep/$'\t'}
    f=("${(@ps:\t:)line}")
    # value: session, window, pane id, socket, and 1 if the pane is on screen
    [[ $f[1] == <-> && -n $f[2] ]] && panes[$f[1]]="$f[2]"$'\t'"$f[3]"$'\t'"$f[4]"$'\t'"$f[5]"$'\t'"${${f[6]:#<1->11}:+0}"
  done
  (( $#panes )) || return 0
  for line in ${(f)"$(ps -axo pid=,ppid=,args= 2>/dev/null)"}; do
    read -r pid ppid args <<<$line
    [[ $pid == <-> && $ppid == <-> ]] || continue
    parent[$pid]=$ppid
    # most processes are no agent: only look closer at lines that could be
    [[ $args == *(claude|copilot|omp|gh)* ]] && _lazyfleet_agent_kind $args && kinds[$pid]=$REPLY
  done
  for pid in ${(k)kinds}; do
    p=$pid n=0
    while [[ -n $p && $p != 0 && $p != 1 ]] && (( n++ < 64 )); do
      if [[ -n $panes[$p] ]]; then
        if [[ -z $seen[$p:$kinds[$pid]] ]]; then
          seen[$p:$kinds[$pid]]=1
          f=("${(@ps:\t:)panes[$p]}")
          line="$f[1]"$'\t'"$f[2]"$'\t'"$kinds[$pid]"
          if [[ -n $detail ]]; then
            _lazyfleet_agent_state $kinds[$pid] $f[4] $f[3]; state=$REPLY
            vis=1; [[ $f[5] == 0 ]] && vis=0
            # finished work that is on screen has been seen: no more "done"
            [[ $state == done && $vis == 1 ]] && { state=idle; _lazyfleet_agent_set $kinds[$pid] $f[4] $f[3] idle }
            line+=$'\t'"$state"$'\t'"$f[3]"$'\t'"$vis"
            _lazyfleet_agent_key $f[4] $f[3]; live+=("$kinds[$pid].$REPLY")
          fi
          reply+=("$line")
        fi
        break
      fi
      p=$parent[$p]
    done
  done
  [[ -n $detail ]] && _lazyfleet_agent_prune $live ${(u)${(v)panes}}
  reply=(${(o)reply})
}

# Remove the hook's records for panes of the tmux servers seen in this round
# that no longer run that agent. Args: the live "kind.key" names, then the
# panes' "session TAB window TAB pane TAB socket TAB visible" values.
_lazyfleet_agent_prune() {
  emulate -L zsh
  local rec v sk
  local -a live socks f
  local -A servers
  for v in "$@"; do
    if [[ $v == *$'\t'* ]]; then
      f=("${(@ps:\t:)v}"); _lazyfleet_agent_key $f[4] ''; servers[$REPLY]=1
    else live+=($v)
    fi
  done
  _lazyfleet_agent_dir
  for rec in $REPLY/*(N.:t); do
    [[ ${live[(Ie)$rec]} -gt 0 ]] && continue
    sk=${rec#*.}
    for v in ${(k)servers}; do
      # a pane's part of the key is always "_" and its number
      [[ $sk == ${v}_<-> ]] && { rm -f $REPLY/$rec 2>/dev/null; break }
    done
  done
}

# Record an agent's state the way bin/lazyfleet-hook does: kind, tmux socket,
# pane id, state
_lazyfleet_agent_set() {
  emulate -L zsh
  local dir file
  _lazyfleet_agent_dir; dir=$REPLY
  [[ -d $dir ]] || return 0
  _lazyfleet_agent_key $2 $3; file=$dir/$1.$REPLY
  print -r -- "$4 $EPOCHSECONDS" >$file.$$ 2>/dev/null && mv -f $file.$$ $file 2>/dev/null || rm -f $file.$$ 2>/dev/null
  return 0
}

# Print a tmux status-bar segment naming the sessions with an agent that waits
# for you ("! app") or has finished ("✓ api"); agents you can see right now do
# not count, and nothing is printed when there are none. For status-right:
#   #(lazyfleet status)
# -p prints plain text, without tmux style codes.
_lazyfleet_status() {
  emulate -L zsh
  local -a o_p f waiting finished
  local line out= s
  zparseopts -D -E p=o_p
  _lazyfleet_agents -d
  for line in $reply; do
    f=("${(@ps:\t:)line}")
    [[ $f[6] == 0 ]] || continue
    s=$f[1]; (( $#o_p )) || s=${s//\#/##}
    case $f[4] in
      (waiting) waiting+=($s) ;;
      (done) finished+=($s) ;;
    esac
  done
  waiting=(${(u)waiting}) finished=(${(u)finished})
  if (( $#waiting )); then
    (( $#o_p )) && out+="! ${(j: :)waiting}" || out+="#[fg=yellow,bold]! ${(j: :)waiting}#[default]"
  fi
  if (( $#finished )); then
    out+="${out:+ }"
    (( $#o_p )) && out+="✓ ${(j: :)finished}" || out+="#[fg=green]✓ ${(j: :)finished}#[default]"
  fi
  [[ -n $out ]] && print -r -- "$out "
  return 0
}

# Called in the background by bin/lazyfleet-hook (inside the agent's pane) when
# an agent starts waiting for you or finishes: refresh the status bars, and
# unless you are looking at that pane, show a short message on the clients that
# are in other sessions. agent_notify=off (or LAZYFLEET_AGENT_NOTIFY=off) keeps
# the messages away; the status segment stays.
_lazyfleet_agent_notify() {
  emulate -L zsh
  local sep='@@lf@@' kind=$1 st=$2 info sess vis msg line c
  local -a f
  [[ -n $TMUX_PANE && $kind == (claude|copilot|omp) && $st == (waiting|done) ]] || return 0
  info=$(_lazyfleet_tmux display-message -p -t $TMUX_PANE "#{session_name}${sep}#{session_attached}#{window_active}#{pane_active}" 2>/dev/null) || return 0
  sess=${info%%${sep}*} vis=${info##*${sep}}
  _lazyfleet_tmux refresh-client -S 2>/dev/null
  _lazyfleet_setting agent_notify LAZYFLEET_AGENT_NOTIFY on
  [[ ${REPLY:l} == (off|no|false|0) ]] && return 0
  [[ $vis == <1->11 ]] && return 0
  case $st in
    (waiting) msg="$_LAZYFLEET_AGENT_ICON[$kind] $sess needs you" ;;
    (done) msg="$_LAZYFLEET_AGENT_ICON[$kind] $sess is done" ;;
  esac
  msg=${msg//\#/##}
  for line in ${(f)"$(_lazyfleet_tmux list-clients -F "#{client_name}${sep}#{client_session}" 2>/dev/null)"}; do
    c=${line%%${sep}*}
    [[ ${line#*${sep}} == $sess ]] && continue
    _lazyfleet_tmux display-message -c $c -d 4000 -- $msg 2>/dev/null
  done
  return 0
}

# --- Claude Code hooks --------------------------------------------------------
# `lazyfleet hooks install` adds hooks to Claude Code's settings.json that run
# bin/lazyfleet-hook, so lazyfleet knows when Claude works, waits for you or is
# done. Entries of ours are told apart by "lazyfleet-hook" in their command;
# everything else in the file is left as it is.

# The jq filters. Our events: name, state, and (for Notification) which
# notifications mean "waiting for you"
typeset -g _LAZYFLEET_HOOKS_JQ_DEF='
  def events: [
    {n:"SessionStart", s:"idle"}, {n:"UserPromptSubmit", s:"working"},
    {n:"PostToolUse", s:"working"},
    {n:"Notification", s:"waiting", m:"permission_prompt|elicitation_dialog"},
    {n:"Stop", s:"done"}, {n:"SessionEnd", s:"clear"} ];
  def ours: (.hooks // []) | any(.[]; (.command // "") | contains("lazyfleet-hook"));
  def without_ours: map(select(ours | not));'
typeset -g _LAZYFLEET_HOOKS_JQ_INSTALL='
  reduce events[] as $e (.;
    .hooks[$e.n] = ((.hooks[$e.n] // []) | without_ours)
      + [ ({hooks: [{type: "command", command: ($hook + " claude " + $e.s)}]}
           + (if $e.m then {matcher: $e.m} else {} end)) ])'
typeset -g _LAZYFLEET_HOOKS_JQ_UNINSTALL='
  if has("hooks") and (.hooks | type == "object") then
    .hooks |= (map_values(if type == "array" then without_ours else . end)
               | with_entries(select(.value != [])))
    | if .hooks == {} then del(.hooks) else . end
  else . end'
typeset -g _LAZYFLEET_HOOKS_JQ_COUNT='
  [ .hooks // {} | to_entries[] | select(.value | type == "array" and any(.[]; ours)) ] | length'

# lazyfleet hooks [install|uninstall|status]
_lazyfleet_hooks() {
  emulate -L zsh
  local sub=${1:-status} file hook jq tmp n bak
  (( $+commands[jq] )) || { _lazyfleet_err "hooks needs jq (https://jqlang.org)"; return 1 }
  file=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
  bak=$file.lazyfleet.bak
  if [[ -e $file ]] && ! jq -e . $file >/dev/null 2>&1; then
    _lazyfleet_err "$file is not valid JSON; left alone"; return 1
  fi
  case $sub in
    (status)
      n=0; [[ -r $file ]] && n=$(jq -r "$_LAZYFLEET_HOOKS_JQ_DEF $_LAZYFLEET_HOOKS_JQ_COUNT" $file)
      if (( n )); then print -r -- "Claude Code hooks installed ($n events) in $file"
      else print -r -- "Claude Code hooks not installed. Install: lazyfleet hooks install"; return 1
      fi ;;
    (install|uninstall)
      if [[ $sub == install ]]; then
        hook=$LAZYFLEET_DIR/bin/lazyfleet-hook
        [[ -x $hook ]] || { _lazyfleet_err "no hook script at $hook"; return 1 }
        hook=${(qq)hook}
        jq="$_LAZYFLEET_HOOKS_JQ_DEF $_LAZYFLEET_HOOKS_JQ_INSTALL"
      else
        [[ -e $file ]] || { print -r -- "Nothing to remove: $file does not exist"; return 0 }
        jq="$_LAZYFLEET_HOOKS_JQ_DEF $_LAZYFLEET_HOOKS_JQ_UNINSTALL"
      fi
      mkdir -p ${file:h} || return 1
      if [[ -e $file && ! -e $bak ]]; then
        cp -p $file $bak || { _lazyfleet_err "could not back up $file"; return 1 }
        print -r -- "Backed up $file to $bak"
      fi
      tmp=$file.lazyfleet.$$
      if [[ -e $file ]]; then jq --arg hook "$hook" "$jq" $file >$tmp
      else print -r -- '{}' | jq --arg hook "$hook" "$jq" >$tmp
      fi || { rm -f $tmp; _lazyfleet_err "could not update $file"; return 1 }
      [[ -e $file ]] && chmod --reference=$file $tmp 2>/dev/null
      mv -f $tmp $file || { rm -f $tmp; return 1 }
      if [[ $sub == install ]]; then print -r -- "Claude Code hooks installed in $file"
      else print -r -- "Claude Code hooks removed from $file"
      fi ;;
    (*) _lazyfleet_err "usage: lazyfleet hooks [install|uninstall|status]"; return 1 ;;
  esac
}

# are the agent icons on? (agent_icons=off or LAZYFLEET_AGENT_ICONS=off turns them off)
_lazyfleet_agent_icons_on() {
  _lazyfleet_setting agent_icons LAZYFLEET_AGENT_ICONS on
  [[ ${REPLY:l} != (off|no|false|0) ]]
}

# What each state looks like after an agent's icon, most urgent first
typeset -ga _LAZYFLEET_AGENT_STATES=(waiting done working)
typeset -gA _LAZYFLEET_AGENT_STATE_MARK=(waiting ! done ✓ working …)
typeset -gA _LAZYFLEET_AGENT_STATE_COLOR=(waiting $'\e[1;33m' done $'\e[32m' working $'\e[2m')

# REPLY=the marks for the agents given as arguments, in a fixed order, like
# "✻2! π✓": the icon, a count above one, and the most urgent state of that
# kind (! waiting for you, ✓ done, … working; idle shows nothing). Coloured,
# unless the first argument is -p. The arguments are kind=count and
# kind:state=count, so an absent kind can not shift the others.
_lazyfleet_agent_marks() {
  emulate -L zsh
  local plain= kind n out= col end arg st sm sc
  local -A cnt
  [[ $1 == -p ]] && { plain=1; shift }
  for arg in "$@"; do cnt[${arg%%=*}]=${arg#*=}; done
  for kind in $_LAZYFLEET_AGENT_KINDS; do
    n=${cnt[$kind]:-0}
    (( n )) || continue
    col=$_LAZYFLEET_AGENT_COLOR[$kind] end=$'\e[0m'
    [[ -n $plain ]] && col= end=
    out+="${out:+ }${col}${_LAZYFLEET_AGENT_ICON[$kind]}${${n:#1}}${end}"
    for st in $_LAZYFLEET_AGENT_STATES; do
      (( ${cnt[$kind:$st]:-0} )) || continue
      sc=$_LAZYFLEET_AGENT_STATE_COLOR[$st]
      [[ -n $plain ]] && sc=
      out+="${sc}${_LAZYFLEET_AGENT_STATE_MARK[$st]}${end}"
      break
    done
  done
  REPLY=$out
}

# Count the agents from _lazyfleet_agents into the caller's associative array
# agtally, keyed "session:kind" (or, with w, "session:window:kind") and, for
# agents whose state is known, "...:kind:state"
_lazyfleet_agent_tally() {
  emulate -L zsh
  local line k
  local -a f
  _lazyfleet_agents -d
  for line in $reply; do
    f=("${(@ps:\t:)line}")
    k=$f[1]; [[ $1 == w ]] && k+=:$f[2]
    agtally[$k:$f[3]]=$(( ${agtally[$k:$f[3]]:-0} + 1 ))
    [[ -n $f[4] ]] && agtally[$k:$f[3]:$f[4]]=$(( ${agtally[$k:$f[3]:$f[4]]:-0} + 1 ))
  done
}

# REPLY=the marks for key $1 (a session, or session:window) from the caller's
# agtally; -p as $2 for plain marks
_lazyfleet_agent_marks_at() {
  emulate -L zsh
  local kind st
  local -a mk
  for kind in $_LAZYFLEET_AGENT_KINDS; do
    [[ -n ${agtally[$1:$kind]} ]] || continue
    mk+=($kind=${agtally[$1:$kind]})
    for st in $_LAZYFLEET_AGENT_STATES; do
      [[ -n ${agtally[$1:$kind:$st]} ]] && mk+=($kind:$st=${agtally[$1:$kind:$st]})
    done
  done
  _lazyfleet_agent_marks $2 $mk
}

# --- pull requests and CI ---------------------------------------------------
# A worktree whose branch has a GitHub pull request shows it in its row:
# "#12 ✓" (checks pass), "#12 ✗" (a check failed), "#12 …" (checks running),
# "#12" (no checks), "#12 draft", "#12 merged" or "#12 closed". The data comes
# from GitHub's REST API through the gh CLI, is fetched in the background at
# most every _LAZYFLEET_PR_TTL seconds per repo, and cached. Drawing a row only
# ever reads the cache, so the TUI never waits for the network.
# pr_status=off (or LAZYFLEET_PR_STATUS=off) turns it off.

typeset -g _LAZYFLEET_PR_TTL=90

# jq program for a repo's pull requests: one tab-separated line each, with
# branch, number, state, draft, merged, head sha, head repo, url and title.
# Control characters are stripped from the title: it is written by whoever
# opened the pull request and ends up on the terminal.
typeset -g _LAZYFLEET_PR_JQ='.[] | [.head.ref, (.number|tostring), .state, ((.draft // false)|tostring), (if .merged_at then "merged" else "-" end), .head.sha, (.head.repo.full_name // "-"), .html_url, (.title | gsub("[\u0001-\u001f\u007f-\u009f‎‏‪-‮⁦-⁩]"; " "))] | @tsv'
typeset -g _LAZYFLEET_PR_JQ_CHECKS='[.check_runs[] | .status + "/" + (.conclusion // "-")] | join(" ")'
typeset -g _LAZYFLEET_PR_JQ_STATUS='"\(.total_count) \(.state)"'

# REPLY=owner/name of repo $1's GitHub origin; fails for any other host
_lazyfleet_ghslug() {
  emulate -L zsh
  setopt extended_glob
  local u h rest
  u=$(git -C $1 remote get-url origin 2>/dev/null) || return 1
  u=${u%/}; u=${u%.git}
  if [[ $u == *://* ]]; then
    u=${u#*://}                  # scheme://[user[:pass]@]host[:port]/owner/name
    h=${u%%/*}; rest=${u#*/}
    [[ $u == */* ]] || return 1
    h=${h##*@}; h=${h%%:*}
  elif [[ $u == *:* && $u != /* ]]; then
    h=${u%%:*}; rest=${u#*:}     # [user@]host:owner/name
    h=${h##*@}
  else
    return 1
  fi
  [[ ${h:l} == (www.|)github.com ]] || return 1
  [[ $rest == [A-Za-z0-9_.-]##/[A-Za-z0-9_.-]## ]] || return 1
  [[ ${rest%%/*} != (.|..) && ${rest##*/} != (.|..) ]] || return 1
  REPLY=$rest
}

_lazyfleet_pr_enabled() {
  (( $+commands[gh] )) || return 1
  _lazyfleet_setting pr_status LAZYFLEET_PR_STATUS on
  [[ ${REPLY:l} != (off|no|false|0) ]]
}

# REPLY=the cache file of GitHub repo $1 (owner/name); creates the directory
_lazyfleet_pr_cachefile() {
  _lazyfleet_tmpdir 2>/dev/null || return 1
  REPLY+=/pr
  [[ -d $REPLY ]] || mkdir -m 700 $REPLY 2>/dev/null
  REPLY+=/${${1:l}//\//%}
}

# REPLY=pass, fail, pending or none, from $1 (the "status/conclusion" words of
# a commit's check runs) and $2 ("count state" of its combined commit status).
# A commit nothing checks has a combined state of "pending" with a count of 0;
# that is none, not pending.
_lazyfleet_pr_ci() {
  emulate -L zsh
  local w fail= pend= pass=
  for w in ${=1}; do
    if [[ ${w%%/*} != completed ]]; then pend=1; continue; fi
    case ${w#*/} in
      (success|neutral|skipped) pass=1 ;;
      (failure|timed_out|cancelled|action_required|startup_failure) fail=1 ;;
      (stale) ;;
      (*) pend=1 ;;
    esac
  done
  if [[ ${2%% *} == <-> ]] && (( ${2%% *} > 0 )); then
    case ${2#* } in
      (failure|error) fail=1 ;;
      (pending) pend=1 ;;
      (success) pass=1 ;;
    esac
  fi
  if [[ -n $fail ]]; then REPLY=fail
  elif [[ -n $pend ]]; then REPLY=pending
  elif [[ -n $pass ]]; then REPLY=pass
  else REPLY=none; fi
}

# _lazyfleet_pr_fetch slug cachefile branch...: ask GitHub about the repo's
# pull requests (and, for open ones on the given branches, their checks) and
# write the cache. If GitHub can not be reached the old rows stay and only the
# time of the attempt moves, so a failure is not retried at once. REPLY=changed
# if the rows differ from before, else same.
_lazyfleet_pr_fetch() {
  emulate -L zsh
  setopt extended_glob no_monitor no_notify
  local slug=$1 f=$2 out line ref st r i sha dir tmp old= new= ok=1 ci
  shift 2
  local -a fl rows
  local -A want best rank
  for ref in "$@"; do want[$ref]=1; done
  [[ -r $f ]] && old=$(tail -n +2 $f 2>/dev/null)
  out=$(command gh api "repos/$slug/pulls?state=all&sort=updated&direction=desc&per_page=100" --jq $_LAZYFLEET_PR_JQ 2>/dev/null) || ok=
  if [[ -n $ok ]]; then
    for line in ${(f)out}; do
      fl=("${(@ps:\t:)line}")
      (( $#fl >= 8 )) || continue
      [[ ${fl[7]:l} == ${slug:l} ]] || continue          # not from a fork
      if [[ $fl[3] == open ]]; then
        [[ $fl[4] == true ]] && st=draft || st=open; r=4
      elif [[ $fl[5] == merged ]]; then st=merged; r=3
      else st=closed; r=2; fi
      # an open pull request beats a merged one beats a closed one; among
      # equals the most recently updated (the first) stays
      (( r > ${rank[$fl[1]]:-0} )) || continue
      rank[$fl[1]]=$r
      best[$fl[1]]=$fl[2]$'\t'$st$'\t'-$'\t'$fl[8]$'\t'${fl[9]//\\\\/\\}$'\t'$fl[6]
    done
    # checks, for the open pull requests that have a worktree here (at most 25)
    _lazyfleet_tmpdir 2>/dev/null && dir=$REPLY/ci.$$.$RANDOM && mkdir -m 700 $dir 2>/dev/null
    if [[ -d $dir ]]; then
      i=0
      for ref in ${(k)best}; do
        [[ -n $want[$ref] ]] || continue
        st=${${best[$ref]#*$'\t'}%%$'\t'*}
        [[ $st == (open|draft) ]] || continue
        sha=${best[$ref]##*$'\t'}
        [[ $sha == [0-9a-f](#c7,64) ]] || continue
        (( i >= 25 )) && break
        (( i++ ))
        {
          command gh api "repos/$slug/commits/$sha/check-runs?per_page=100" --jq $_LAZYFLEET_PR_JQ_CHECKS >$dir/$i.c 2>/dev/null || : >$dir/$i.c
          command gh api "repos/$slug/commits/$sha/status" --jq $_LAZYFLEET_PR_JQ_STATUS >$dir/$i.s 2>/dev/null || : >$dir/$i.s
        } &
        print -r -- $ref >$dir/$i.r
      done
      wait
      for (( r = 1; r <= i; r++ )); do
        [[ -r $dir/$r.r ]] || continue
        ref=$(<$dir/$r.r)
        _lazyfleet_pr_ci "$(<$dir/$r.c)" "$(<$dir/$r.s)"; ci=$REPLY
        best[$ref]=${best[$ref]%%$'\t'*}$'\t'${${best[$ref]#*$'\t'}%%$'\t'*}$'\t'$ci$'\t'${best[$ref]#*$'\t'*$'\t'*$'\t'}
      done
      rm -rf $dir
    fi
    # (the head commit stays in the cache: prune compares it with a branch)
    for ref in ${(ok)best}; do rows+=($ref$'\t'$best[$ref]); done
    new=${(F)rows}
  else
    new=$old
  fi
  tmp=$f.$$
  [[ -n $ok ]] && st=ok || st=fail
  {
    print -r -- "#lazyfleet-pr 1 $EPOCHSECONDS $st"
    if [[ -n $new ]]; then print -r -- $new; fi
  } >|$tmp && mv -f $tmp $f || { rm -f $tmp; return 1 }
  [[ $new == $old ]] && REPLY=same || REPLY=changed
  [[ -n $ok ]]
}

# _lazyfleet_pr_read slug: put the cached pull requests of repo $1 into the
# caller's associative array prs, as "slug:branch" ->
# "number<TAB>state<TAB>ci<TAB>url<TAB>title<TAB>head sha". REPLY=seconds since the last
# attempt to refresh the cache (empty: never). Fails without a usable cache.
_lazyfleet_pr_read() {
  emulate -L zsh
  local slug=${1:l} f line content stamp
  local -a fl hf lines
  REPLY=
  _lazyfleet_pr_cachefile $slug || return 1; f=$REPLY
  REPLY=
  [[ -r $f ]] || return 1
  content=$(<$f) 2>/dev/null
  lines=("${(@f)content}")
  hf=(${=lines[1]})
  [[ $hf[1] == '#lazyfleet-pr' && $hf[2] == 1 && $hf[3] == <-> ]] || return 1
  stamp=$hf[3]
  for line in ${lines[2,-1]}; do
    fl=("${(@ps:\t:)line}")
    (( $#fl >= 5 )) || continue
    prs[$slug:$fl[1]]=$fl[2]$'\t'$fl[3]$'\t'$fl[4]$'\t'$fl[5]$'\t'${fl[6]//[[:cntrl:]]/ }$'\t'${fl[7]//[^0-9a-f]/}
  done
  REPLY=$(( EPOCHSECONDS - stamp ))
}

# REPLY=the row mark for pull request fields $1 (number) $2 (state) $3 (ci);
# -p as $4 for no colours
_lazyfleet_pr_mark() {
  emulate -L zsh
  local n=$1 st=$2 ci=$3 col= sym= end=$'\e[0m'
  case $st in
    (open) case $ci in
             (pass) col=$'\e[32m' sym=' ✓' ;;
             (fail) col=$'\e[31m' sym=' ✗' ;;
             (pending) col=$'\e[33m' sym=' …' ;;
           esac ;;
    (draft) col=$'\e[2m' sym=' draft' ;;
    (merged) col=$'\e[35m' sym=' merged' ;;
    (closed) col=$'\e[2m' sym=' closed' ;;
    (*) REPLY=; return 1 ;;
  esac
  [[ $4 == -p ]] && col=
  [[ -z $col ]] && end=
  REPLY="${col}#${n}${sym}${end}"
}

# Look for pull requests that are out of date, and refresh them in a detached
# job that, once it has found something new, has the TUI's fzf reload. Arguments
# are pairs: a repo's owner/name and its worktrees' branches (space separated).
_lazyfleet_pr_kick() {
  emulate -L zsh
  setopt extended_glob
  local slug f age bin=${(q)LAZYFLEET_DIR}/bin/lazyfleet
  local -a todo dead
  local -A prs
  while (( $# >= 2 )); do
    slug=$1
    _lazyfleet_pr_cachefile $slug || { shift 2; continue }; f=$REPLY
    prs=()
    _lazyfleet_pr_read $slug; age=$REPLY
    if [[ -z $age ]] || (( age >= _LAZYFLEET_PR_TTL )); then
      # one refresh per repo at a time; a lock older than two minutes is dead
      if mkdir $f.lock 2>/dev/null; then
        todo+=($slug $f $2)
      else
        dead=($f.lock(N/mm+2))
        (( $#dead )) && rmdir $f.lock 2>/dev/null
      fi
    fi
    shift 2
  done
  (( $#todo )) || return 0
  {
    local changed= s file brs
    while (( $#todo >= 3 )); do
      s=$todo[1] file=$todo[2] brs=$todo[3]; shift 3 todo
      _lazyfleet_pr_fetch $s $file ${=brs}
      [[ $REPLY == changed ]] && changed=1
      rmdir $file.lock 2>/dev/null
    done
    [[ -n $changed ]] && _lazyfleet_fzfpost "transform($bin _prdone)"
  } </dev/null >/dev/null 2>&1 &!
}

# fzf action once a refresh found something new: reload the worktrees (with
# their git status) unless the list is not on them or is still loading
_lazyfleet_prdone() {
  local bin=${(q)LAZYFLEET_DIR}/bin/lazyfleet lbl=${${FZF_LIST_LABEL# }% }
  case $lbl in
    (Worktrees*' · loading…'|Worktrees*' · checking status…') ;;
    (Worktrees*) print -r -- "reload-sync($bin _rows -s -L)" ;;
  esac
}

# --- rows for the TUI: "kind<TAB>path<TAB>display" ---------------------------

# _lazyfleet_rows [-s (with git status)] [-p (plain)] [-L | repo name filter]
# -L: the filter of the Worktrees view's list label ($FZF_LIST_LABEL)
_lazyfleet_rows() {
  setopt local_options no_monitor no_notify
  local -a o_s o_p o_l
  zparseopts -D -E s=o_s p=o_p L=o_l
  local only=$1 repo e p s i tmp wn=0 wb=0 line d
  (( $#o_l )) && { _lazyfleet_labelrepo; only=$REPLY }
  local c_repo=$'\e[34m' c_live=$'\e[32m' c_st=$'\e[33m' c_dk=$'\e[36m' c_off=$'\e[0m'
  (( $#o_p )) && c_repo= c_live= c_st= c_dk= c_off=
  local -A live dk agtally prs
  local -a repos paths names branches lives stats docks sess pslugs rbr kicks fl
  local pr_on= pslug pv prm
  for s in ${(f)"$(_lazyfleet_tmux list-sessions -F '#S' 2>/dev/null)"}; do live[$s]=1; done
  _lazyfleet_pr_enabled && pr_on=1
  _lazyfleet_repos; repos=($reply)
  for repo in $repos; do
    [[ -n $only && ${repo:t} != $only ]] && continue
    _lazyfleet_worktrees $repo
    pslug= rbr=()
    if [[ -n $pr_on ]] && _lazyfleet_ghslug $repo; then
      pslug=$REPLY
      _lazyfleet_pr_read $pslug
    fi
    for e in $reply; do
      p=${e%%$'\t'*}
      _lazyfleet_session $repo $p ${e##*$'\t'}
      paths+=($p); names+=(${repo:t}); branches+=(${${e#*$'\t'}%$'\t'*})
      lives+=("${live[$REPLY]:+●}"); stats+=(''); docks+=(''); sess+=($REPLY)
      pslugs+=($pslug); rbr+=($branches[-1])
      (( $#names[-1] > wn )) && wn=$#names[-1]
      (( $#branches[-1] > wb )) && wb=$#branches[-1]
    done
    [[ -n $pslug ]] && kicks+=($pslug "${(j: :)rbr}")
  done
  # out of date pull request data is refreshed in the background
  (( $#o_s && $#kicks )) && _lazyfleet_pr_kick $kicks
  _lazyfleet_agent_icons_on && _lazyfleet_agent_tally
  if (( $#o_s && $#paths )); then
    _lazyfleet_tmpdir || return 1
    tmp=$REPLY/status.$$.$RANDOM
    mkdir -m 700 $tmp || return 1
    for i in {1..$#paths}; do _lazyfleet_wtstatus $paths[i] >$tmp/$i & done
    { _lazyfleet_containers; print -rl -- $reply >$tmp/docker } &
    wait
    for i in {1..$#paths}; do stats[i]=$(<$tmp/$i); done
    for line in ${(f)"$(<$tmp/docker)"}; do
      d=${${line%%$'\t'*}:A}; dk[$d]=$(( ${dk[$d]:-0} + 1 ))
    done
    for i in {1..$#paths}; do docks[i]=${dk[${paths[i]:A}]:+🐳${dk[${paths[i]:A}]}}; done
    rm -rf $tmp
  fi
  _lazyfleet_pulldir
  for (( i = 1; i <= $#paths; i++ )); do
    [[ -e $REPLY/${paths[i]//\//%} ]] && stats[i]="⟳ pulling${stats[i]:+ $stats[i]}"
    prm=
    if [[ -n $pslugs[i] ]]; then
      pv=${prs[${pslugs[i]:l}:${branches[i]}]}
      if [[ -n $pv ]]; then
        fl=("${(@ps:\t:)pv}")
        _lazyfleet_pr_mark $fl[1] $fl[2] $fl[3] ${o_p:+-p} && prm=$REPLY
      fi
    fi
    _lazyfleet_agent_marks_at $sess[i] ${o_p:+-p}
    printf 'w\t%s\t%s%-*s%s  %-*s  %s%1s%s %s%s%s%s%s%s%s%s\n' $paths[i] \
      "$c_repo" $wn $names[i] "$c_off" $wb $branches[i] \
      "$c_live" "$lives[i]" "$c_off" "$c_st" "$stats[i]" "$c_off" \
      "$c_dk" "${docks[i]:+${stats[i]:+ }$docks[i]}" "$c_off" "${prm:+ $prm}" "${REPLY:+ $REPLY}"
  done
}

_lazyfleet_reporows() {
  local repo s n l c e line wn=0
  local -a repos sessions containers
  local -A wts
  sessions=(${(f)"$(_lazyfleet_tmux list-sessions -F '#S' 2>/dev/null)"})
  _lazyfleet_containers -c; containers=($reply)
  _lazyfleet_repos; repos=($reply)
  for repo in $repos; do (( $#repo:t > wn )) && wn=$#repo:t; done
  for repo in $repos; do
    _lazyfleet_worktrees $repo; n=$#reply
    wts=(); for e in $reply; do wts[${${e%%$'\t'*}:A}]=1; done
    l=0 c=0
    _lazyfleet_session $repo $repo 1
    for s in $sessions; do [[ $s == $REPLY || $s == $REPLY/* ]] && (( l++ )); done
    for line in $containers; do (( ${+wts[${${line%%$'\t'*}:A}]} )) && (( c++ )); done
    printf 'r\t%s\t\e[34m%-*s\e[0m  %d worktree%s  \e[32m%s\e[0m\e[36m%s\e[0m\n' $repo $wn ${repo:t} \
      $n ${${n:#1}:+s} "${${l:#0}:+● $l live}" "${${c:#0}:+  🐳 $c running}"
  done
}

# Branches of repo $1 that could get a new worktree, most recent first:
# local and origin/* (deduped), minus the ones already checked out
_lazyfleet_branches() {
  local ref e
  local -A skip
  _lazyfleet_worktrees $1
  for e in $reply; do skip[${${e#*$'\t'}%$'\t'*}]=1; done
  for ref in ${(f)"$(git -C $1 for-each-ref --sort=-committerdate --format='%(refname)' refs/heads refs/remotes/origin)"}; do
    ref=${${ref#refs/heads/}#refs/remotes/origin/}
    [[ $ref == HEAD || -n $skip[$ref] ]] && continue
    skip[$ref]=1
    print -r -- $ref
  done
}

# Unregistered git repos (~-abbreviated) under the search= setting, else the
# usual project dirs in $HOME; the repo containing $PWD comes first
_lazyfleet_findrepos() {
  local d depth
  local -a roots
  local -A skip
  _lazyfleet_repos
  for d in $reply; do skip[$d]=1; done
  if _lazyfleet_toplevel && [[ -z $skip[$REPLY] ]]; then
    skip[$REPLY]=1; print -r -- ${REPLY/#$HOME/\~}
  fi
  _lazyfleet_setting search_depth LAZYFLEET_SEARCH_DEPTH 4; depth=$REPLY
  _lazyfleet_setting search LAZYFLEET_SEARCH
  if [[ -n $REPLY ]]; then
    roots=(${~=REPLY}(N/))
  else
    roots=($HOME/{Projects,projects,code,src,dev,work,git,repos,workspace}(N/))
    (( $#roots )) || roots=($HOME)
  fi
  (( $#roots )) || return 0
  command find -L $roots -maxdepth $depth \
    \( -name .git -type d -print -prune \) -o \
    \( \( -name '.?*' -o -name node_modules -o -name vendor -o -name Library \) -prune \) 2>/dev/null |
    while read -r d; do
      d=${d%/.git}
      [[ -n $skip[$d] ]] && continue
      print -r -- ${d/#$HOME/\~}
    done
}

# Fuzzy-pick a line from stdin. REPLY=the pick, or the typed query when
# nothing matches or with ctrl-n. Args: label, prompt.
_lazyfleet_pick() {
  local out
  local -a lines
  out=$(fzf --layout reverse --style full --print-query --no-sort \
    --border-label " $1 " --prompt "$2" \
    --header 'enter pick (or the typed name if nothing matches)   ctrl-n use typed name   esc cancel' \
    --bind 'ctrl-n:print-query')
  (( $? == 130 || $? == 2 )) && return 1
  lines=("${(@f)out}")
  REPLY=${lines[2]:-$lines[1]}
  [[ -n $REPLY ]]
}

# One row per tmux window: "t<TAB>=session:index<TAB>display"; ● marks the
# window an attached client is looking at
_lazyfleet_winrows() {
  local line ws=0 wn=0 wc=0 i k
  # tmux >= 3.4 turns control characters (tabs) in -F output into "_" unless
  # it writes to a terminal, so use a printable ASCII separator (safe in any
  # locale) and turn it into tabs
  local sep='@@lf@@'
  local -a f S N C P M keyed
  local -A agtally
  # by session name, then window number
  for line in ${(f)"$(_lazyfleet_tmux list-windows -a -F "#{session_name}${sep}#{window_index}:#{window_name}${sep}#{pane_current_command}${sep}#{pane_current_path}${sep}#{?#{&&:#{window_active},#{session_attached}},●,}" 2>/dev/null)"}; do
    line=${line//$sep/$'\t'}
    f=("${(@ps:\t:)line}")
    keyed+=("${f[1]:l}"$'\0'"${(l:6::0:)${f[2]%%:*}}"$'\0'"$line")
  done
  for line in ${${(o)keyed}#*$'\0'*$'\0'}; do
    f=("${(@ps:\t:)line}")
    S+=($f[1]); N+=($f[2]); C+=($f[3]); P+=(${f[4]/#$HOME/\~}); M+=("$f[5]")
    (( $#f[1] > ws )) && ws=$#f[1]
    (( $#f[2] > wn )) && wn=$#f[2]
    (( $#f[3] > wc )) && wc=$#f[3]
  done
  _lazyfleet_agent_icons_on && _lazyfleet_agent_tally w
  for (( i = 1; i <= $#S; i++ )); do
    k=$S[i]:${N[i]%%:*}
    _lazyfleet_agent_marks_at $k
    printf 't\t=%s:%s\t\e[34m%-*s\e[0m  %-*s  \e[33m%-*s\e[0m  %s \e[32m%s\e[0m%s\n' \
      $S[i] ${N[i]%%:*} $ws $S[i] $wn $N[i] $wc $C[i] $P[i] "$M[i]" "${REPLY:+ $REPLY}"
  done
}

_lazyfleet_names() {
  local repo e
  local -a repos
  _lazyfleet_repos; repos=($reply)
  for repo in $repos; do
    _lazyfleet_worktrees $repo
    for e in $reply; do
      _lazyfleet_session $repo ${e%%$'\t'*} ${e##*$'\t'}
      print -r -- $REPLY
    done
  done
}

# REPLY=preview of tmux window $1: a header line, then the pane's last
# screenful without its trailing blank lines; fails once the window is gone
_lazyfleet_winframe() {
  local head
  local -a out
  head=$(_lazyfleet_tmux display-message -p -t $1 '#{pane_current_command}  #{pane_current_path}' 2>/dev/null) || return 1
  out=("${(@f)$(_lazyfleet_tmux capture-pane -ep -t $1)}")
  local n=$(( ${FZF_PREVIEW_LINES:-40} - 2 ))
  (( $#out > n )) && out=(${out[-n,-1]})
  REPLY=$'\e[1m'${1#=}$'\e[0m  '$head$'\n\n'${(F)out}
}

# Print the pull request of worktree $1's branch, if the cache knows one
_lazyfleet_pr_preview() {
  emulate -L zsh
  local -A prs
  local slug br pv age what title
  local -a fl
  _lazyfleet_pr_enabled || return 0
  _lazyfleet_ghslug $1 || return 0; slug=$REPLY
  br=$(git -C $1 branch --show-current 2>/dev/null)
  [[ -n $br ]] || return 0
  _lazyfleet_pr_read $slug || return 0; age=$REPLY
  pv=$prs[${slug:l}:$br]
  [[ -n $pv ]] || return 0
  fl=("${(@ps:\t:)pv}")
  title=$fl[5]    # already free of control characters: _lazyfleet_pr_read strips them
  what=$fl[2]
  if [[ $fl[2] == (open|draft) ]]; then
    case $fl[3] in
      (pass) what+=' · checks passing' ;;
      (fail) what+=' · checks failing' ;;
      (pending) what+=' · checks running' ;;
      (*) what+=' · no checks' ;;
    esac
  fi
  print
  print -r -- $'\e[1mPR #'$fl[1]$'\e[0m  '$title
  print -r -- "   $what"$'  \e[2m'$fl[4]$'\e[0m'
  (( age > 600 )) && print -r -- $'   \e[2m(as of '$(( age / 60 ))$' min ago)\e[0m'
  return 0
}

# _lazyfleet_preview [-f] kind path — -f: a window preview keeps redrawing
# (when its pane changes) until fzf stops it for another row
_lazyfleet_preview() {
  local -a o_f
  zparseopts -D -E f=o_f
  local kind=$1 p=$2 e
  if [[ -z $p ]]; then
    [[ $FZF_LIST_LABEL == *Windows* ]] && print 'No tmux windows.' || print 'No repos yet — press a to add one.'
    return
  fi
  if [[ $kind == t ]]; then
    local last
    _lazyfleet_winframe $p || return
    print -r -- $REPLY
    (( $#o_f )) || return 0
    zmodload zsh/zselect
    last=$REPLY
    # no fork per tick: zselect -t sleeps (in 1/100 s) without a sleep process
    while zselect -t 50 || :; _lazyfleet_winframe $p; do
      [[ $REPLY == $last ]] && continue
      last=$REPLY
      print -rn -- $'\e[2J'; print -r -- $REPLY
    done
    return
  fi
  if [[ $kind == r ]]; then
    print -r -- $'\e[1m'${p:t}$'\e[0m  '${p/#$HOME/\~}
    print
    for e in ${(f)"$(git -C $p worktree list)"}; do print -r -- ${e/#$HOME/\~}; done
    _lazyfleet_projconf $p
    [[ -r $REPLY ]] && { print; print -r -- $'\e[1m'${REPLY/#$HOME/\~}$'\e[0m'; print -r -- "$(<$REPLY)" }
    [[ -r $p/.lazyfleet ]] && { print; print -r -- $'\e[1m.lazyfleet\e[0m'; print -r -- "$(<$p/.lazyfleet)" }
    return
  fi
  local s
  local m=0
  _lazyfleet_toplevel $p && { [[ $p == ${REPLY:A} ]] && m=1; _lazyfleet_session $REPLY $p $m }
  s=$REPLY
  print -r -- $'\e[1m'$s$'\e[0m  '${p/#$HOME/\~}
  local wins
  if wins=$(_lazyfleet_tmux list-windows -t "=$s" -F '#I:#W' 2>/dev/null); then
    print -r -- $'\e[32m● session\e[0m  '${(j:  :)${(f)wins}}
  else
    print -r -- $'\e[2m○ no session\e[0m'
  fi
  _lazyfleet_containers_in $p -c
  if (( $#reply )); then
    print -r -- $'\e[36m🐳 '$#reply' running\e[0m'
    for e in $reply[1,10]; do e=${e#*$'\t'}; print -r -- "   ${e%%$'\t'*}  "$'\e[2m'"${${e#*$'\t'}%%$'\t'*}"$'\e[0m'; done
    (( $#reply > 10 )) && print -r -- "   … $(( $#reply - 10 )) more"
  fi
  _lazyfleet_pr_preview $p
  print
  git -C $p --no-optional-locks -c color.status=always status -sb | head -n 30
  print
  git -C $p log --oneline --color=always -n 15
}

# --- commands ---------------------------------------------------------------

_lazyfleet_add() {
  _lazyfleet_toplevel ${1:-$PWD} || { _lazyfleet_err "not a git repo: ${1:-$PWD}"; return 1 }
  local repo=$REPLY r name
  _lazyfleet_repos
  # sessions (<repo>/...) and worktree dirs (<worktrees>/<repo>/...) are keyed
  # by the repo's name, so two registered repos can't share one — compared as
  # session names, where app.js and app-js are the same
  _lazyfleet_session $repo $repo 1; name=$REPLY
  for r in $reply; do
    _lazyfleet_session $r $r 1
    [[ $r != $repo && $REPLY == $name ]] &&
      { _lazyfleet_err "a repo named ${repo:t} is already registered: $r (lazyfleet forget it first)"; return 1 }
  done
  if (( ! ${reply[(Ie)$repo]} )); then
    _lazyfleet_regfile
    mkdir -p ${REPLY:h}
    print -r -- $repo >>$REPLY
  fi
  print -r -- $repo
}

_lazyfleet_forget() {
  local r=$1
  if [[ -z $r ]]; then _lazyfleet_toplevel || { _lazyfleet_err 'usage: lazyfleet forget <repo>'; return 1 }; r=$REPLY; fi
  _lazyfleet_find_repo $r || { _lazyfleet_err "unknown repo: $r"; return 1 }
  local repo=$REPLY
  _lazyfleet_repos
  local -a keep=(${reply:#$repo})
  _lazyfleet_regfile
  print -rl -- $keep >| $REPLY
}

_lazyfleet_ls() {
  local k p d
  _lazyfleet_rows -s -p | while IFS=$'\t' read -r k p d; do print -r -- "$d  $p"; done
}

# --- new --pr / new --issue --------------------------------------------------
# What GitHub says about a pull request or an issue is data, not instructions:
# the branch name is checked by git, and an issue's title only ever becomes
# [a-z0-9-] in a branch name.

# Common to both: REPLY=the repo's owner/name, after checking that the number
# is a number and that gh is there. Args: repo dir, number.
_lazyfleet_new_gh() {
  emulate -L zsh
  [[ $2 == <1-999999999> ]] || { _lazyfleet_err "not a number: ${2//[[:cntrl:]]/ }"; return 1 }
  (( $+commands[gh] )) || { _lazyfleet_err "this needs gh (https://cli.github.com), logged in"; return 1 }
  _lazyfleet_ghslug $1 || { _lazyfleet_err "this needs a GitHub remote called origin"; return 1 }
}

# REPLY=the branch to work on for pull request $2 of repo $1, fetched. A
# pull request from a fork has no branch here, so it gets a local branch pr-N.
_lazyfleet_new_from_pr() {
  emulate -L zsh
  local slug out ref head
  local -a f
  _lazyfleet_new_gh $1 $2 || return 1
  slug=$REPLY
  out=$(gh api repos/$slug/pulls/$2 --jq '[.head.ref, (.head.repo.full_name // "-")] | @tsv' 2>/dev/null) ||
    { _lazyfleet_err "could not read pull request #$2 of $slug (does it exist, and is gh logged in?)"; return 1 }
  f=("${(@ps:\t:)out}")
  ref=$f[1] head=$f[2]
  if [[ ${head:l} != ${slug:l} ]]; then
    # a fork, or a repository that is gone: GitHub keeps the commits as pull/N/head
    if ! git -C $1 show-ref -q --verify refs/heads/pr-$2; then
      git -C $1 fetch -q origin pull/$2/head:refs/heads/pr-$2 2>/dev/null ||
        { _lazyfleet_err "could not fetch pull request #$2"; return 1 }
    fi
    REPLY=pr-$2
    return 0
  fi
  # (a leading - is refused here too: the name goes to git fetch as an argument)
  [[ -n $ref && $ref != -* ]] && git check-ref-format --branch $ref >/dev/null 2>&1 ||
    { _lazyfleet_err "pull request #$2 has a branch name git does not accept"; return 1 }
  git -C $1 fetch -q origin $ref 2>/dev/null ||
    { _lazyfleet_err "could not fetch branch $ref of pull request #$2 (has it been deleted?)"; return 1 }
  REPLY=$ref
}

# REPLY=a branch name for issue $2 of repo $1: issue-<number>-<words of the title>
_lazyfleet_new_from_issue() {
  emulate -L zsh
  setopt extended_glob
  local slug out title name
  _lazyfleet_new_gh $1 $2 || return 1
  slug=$REPLY
  out=$(gh api repos/$slug/issues/$2 --jq '[.title, (.pull_request != null | tostring)] | @tsv' 2>/dev/null) ||
    { _lazyfleet_err "could not read issue #$2 of $slug (does it exist, and is gh logged in?)"; return 1 }
  [[ ${out##*$'\t'} == true ]] && { _lazyfleet_err "#$2 is a pull request: use --pr $2"; return 1 }
  title=${out%$'\t'*}
  name=${${${${title:l}//[^a-z0-9]##/-}#-}%-}
  name=${name[1,40]}; name=${name%-}
  REPLY=issue-$2${name:+-$name}
  # by construction a plain name; git has the last word
  git check-ref-format --branch $REPLY >/dev/null 2>&1 || { _lazyfleet_err "could not make a branch name for issue #$2"; return 1 }
}

# lazyfleet new <branch> | --pr <n> | --issue <n> [-r repo] [-b base] [--no-open] [-q (summary only in the session)]
_lazyfleet_new() {
  local -a o_r o_b o_n o_q o_pr o_is
  zparseopts -D -E -F r:=o_r b:=o_b -no-open=o_n q=o_q -pr:=o_pr -issue:=o_is || return 1
  local _lazyfleet_quiet=${o_q:+1}
  local br=$1 repo base p src=
  # zparseopts leaves the = of --pr=7 on the value
  (( $#o_pr )) && o_pr[2]=${o_pr[2]#=}
  (( $#o_is )) && o_is[2]=${o_is[2]#=}
  local usage='usage: lazyfleet new <branch> | --pr <number> | --issue <number>  [-r repo] [-b base] [--no-open]'
  (( $#o_pr + $#o_is > 2 )) && { _lazyfleet_err "give --pr or --issue, not both"; return 1 }
  if (( $#o_pr + $#o_is )); then
    [[ -z $br ]] || { _lazyfleet_err "give a branch, or --pr / --issue, not both"; return 1 }
  elif [[ -z $br ]]; then
    _lazyfleet_err $usage; return 1
  fi
  if (( $#o_r )); then
    _lazyfleet_find_repo $o_r[2] || _lazyfleet_toplevel $o_r[2] || { _lazyfleet_err "unknown repo: $o_r[2]"; return 1 }
  else
    _lazyfleet_toplevel || { _lazyfleet_err 'not in a repo; pass -r <repo>'; return 1 }
  fi
  repo=$REPLY
  if (( $#o_pr )); then
    _lazyfleet_new_from_pr $repo $o_pr[2] || return 1
    br=$REPLY src="pull request #$o_pr[2]"
  elif (( $#o_is )); then
    _lazyfleet_new_from_issue $repo $o_is[2] || return 1
    br=$REPLY src="issue #$o_is[2]"
  fi
  # unregistered (e.g. a name clash) means no worktree: it'd share that name's
  # sessions and dir, and be missing from the lists
  _lazyfleet_add $repo >/dev/null || return 1
  _lazyfleet_setting worktrees LAZYFLEET_WORKTREES ~/.lazyfleet/worktrees
  p=${~REPLY}/${repo:t}/${br//\//-}
  [[ -e $p ]] && { _lazyfleet_err "already exists: $p"; return 1 }
  # what we did goes to stderr (stdout is the path, for scripts and the TUI)
  local how
  typeset -ga _lazyfleet_sum=()
  if git -C $repo show-ref -q --verify refs/heads/$br; then
    how='existing local branch'
    git -C $repo worktree add -q $p $br
  elif git -C $repo show-ref -q --verify refs/remotes/origin/$br; then
    how="new, tracking origin/$br"
    git -C $repo worktree add -q --track -b $br $p origin/$br
  else
    base=${o_b[2]:-$(git -C $repo symbolic-ref -q --short refs/remotes/origin/HEAD)}
    how="new, from ${base:-HEAD}"
    git -C $repo worktree add -q -b $br $p ${base:-HEAD}
  fi || return 1
  _lazyfleet_say "lazyfleet: new worktree ${p/#$HOME/~}"
  _lazyfleet_say "  branch  $br" "($how)"
  [[ -n $src ]] && _lazyfleet_say "  from    $src"

  local f
  local -a copied skipped
  if _lazyfleet_conf copy $p $repo; then
    for f in ${=REPLY}; do
      if [[ -e $repo/$f ]]; then
        # setup may need these files: don't start it without them
        mkdir -p $p/${f:h} && cp -R $repo/$f $p/$f || {
          _lazyfleet_err "could not copy $f into ${p/#$HOME/~}; the worktree is there, but setup didn't run"
          return 1
        }
        copied+=($f)
      else
        skipped+=($f)
      fi
    done
    (( $#copied )) && _lazyfleet_say "  copy    $copied " "from ${repo/#$HOME/~} ($_lazyfleet_from)"
    for f in $skipped; do _lazyfleet_say "  ${(l:8:)}skipped $f: not in the main worktree"; done
  else
    _lazyfleet_say "  copy   " "nothing (no copy= configured)"
  fi
  _lazyfleet_session $repo $p 0
  local s=$REPLY
  if _lazyfleet_conf setup $p $repo; then
    local cmd=$REPLY
    if [[ $cmd == *$'\n'* ]]; then
      _lazyfleet_say "  setup   ${#${(f)cmd}}-line script" "($_lazyfleet_from) → running in session $s:"
      for f in ${(f)cmd}; do _lazyfleet_say "          " "$f"; done
    else
      _lazyfleet_say "  setup   $cmd " "($_lazyfleet_from) → running in session $s"
    fi
    _lazyfleet_setup_run $s $p $cmd $_lazyfleet_sum || return 1
  else
    _lazyfleet_say "  setup  " "nothing (no setup= configured)"
    _lazyfleet_ensure $p || return 1
  fi
  print -r -- $p
  (( $#o_n )) || _lazyfleet_open_path $p
}

# lazyfleet open [worktree] — no match falls back to the TUI with a query
_lazyfleet_open() {
  if [[ -z $1 ]]; then
    local top
    top=$(git rev-parse --show-toplevel 2>/dev/null) && { _lazyfleet_open_path $top; return }
    _lazyfleet_ui
  elif _lazyfleet_resolve $1; then
    _lazyfleet_open_path $REPLY
  else
    _lazyfleet_ui $1
  fi
}

# REPLY="locked by <owner>" / "locked (<reason>)" if worktree $1 is locked
# (e.g. by Supacode, which writes JSON with an owner); fails if it isn't
_lazyfleet_locked() {
  local gd why
  gd=$(git -C $1 rev-parse --absolute-git-dir 2>/dev/null) && [[ -e $gd/locked ]] || return 1
  why=$(<$gd/locked)
  if [[ $why == *'"owner":"'* ]]; then
    REPLY="locked by ${${why#*\"owner\":\"}%%\"*}"
  else
    REPLY="locked${why:+ ($why)}"
  fi
}

# lazyfleet rm [worktree] [-f] [-D] — -f also overrides a lock
# reply=("kind<TAB>window<TAB>state" ...): the agents running in tmux session
# $1 (the state is empty when it is not known)
_lazyfleet_session_agents() {
  emulate -L zsh
  local line
  local -a f found
  _lazyfleet_agents -d
  for line in $reply; do
    f=("${(@ps:\t:)line}")
    [[ $f[1] == $1 ]] && found+=("$f[3]"$'\t'"$f[2]"$'\t'"$f[4]")
  done
  reply=($found)
}

# Tell (on stdout) which agents $@ ("kind<TAB>window<TAB>state" entries) would
# be ended by closing session $s
_lazyfleet_agents_warning() {
  emulate -L zsh
  local s=$1 e kind win state
  shift
  print -r -- $'\e[33mWarning:\e[0m '"$# agent(s) running in this worktree's tmux session ($s):"
  for e in "$@"; do
    kind=${e%%$'\t'*}; e=${e#*$'\t'}; win=${e%%$'\t'*}; state=${e#*$'\t'}
    print -r -- "   $kind (window $win${state:+, $state})"
  done
}

_lazyfleet_rm() {
  local -a o_f o_D rmf
  zparseopts -D -E -F f=o_f D=o_D || return 1
  local p repo br s force locked rc=0
  local -a busy
  if [[ -n $1 ]]; then
    _lazyfleet_resolve $1 || { _lazyfleet_err "no unique worktree for '$1' ($REPLY matches)"; return 1 }
    p=$REPLY
  else
    p=$(git rev-parse --show-toplevel 2>/dev/null) || { _lazyfleet_err 'usage: lazyfleet rm <worktree>'; return 1 }
  fi
  _lazyfleet_toplevel $p || { _lazyfleet_err "not a git worktree: $p"; return 1 }
  repo=$REPLY
  [[ ${p:A} == ${repo:A} ]] && { _lazyfleet_err "refusing to remove the main worktree: $p"; return 1 }
  (( $#o_f )) && force=1
  if _lazyfleet_locked $p; then
    locked=1
    if [[ -z $force ]]; then
      [[ -t 0 ]] || { _lazyfleet_err "$p is $REPLY (use -f)"; return 1 }
      print -rn -- "${p/#$HOME/~} is $REPLY. Remove anyway? [y/N] "
      read -q </dev/tty || { print; return 1 }
      print
      force=1
    fi
  fi
  # only an explicit -f skips this: accepting the lock prompt above doesn't
  if (( ! $#o_f )) && [[ -n $(git -C $p status --porcelain 2>/dev/null) ]]; then
    [[ -t 0 ]] || { _lazyfleet_err "$p has changes (use -f)"; return 1 }
    print -rn -- "${p/#$HOME/~} has uncommitted changes. Remove anyway? [y/N] "
    read -q </dev/tty || { print; return 1 }
    print
    force=1
  fi
  br=$(git -C $p branch --show-current)
  _lazyfleet_session $repo $p 0; s=$REPLY
  # removing the worktree closes its session, and with it the agents in there;
  # like the changes above, only an explicit -f skips the question
  if (( ! $#o_f )); then
    _lazyfleet_session_agents $s
    if (( $#reply )); then
      busy=("${reply[@]}")
      [[ -t 0 ]] || { _lazyfleet_err "$p has $#busy agent(s) running in session $s (use -f)"; return 1 }
      _lazyfleet_agents_warning $s "${busy[@]}"
      print -rn -- "Removing the worktree ends them. Remove anyway? [y/N] "
      read -q </dev/tty || { print; return 1 }
      print
    fi
  fi
  # git wants --force twice for a locked worktree
  [[ -n $force ]] && rmf=(--force ${locked:+--force})
  _lazyfleet_step "Removing ${p/#$HOME/~} (this can take a while with node_modules)"
  git -C $repo worktree remove $rmf $p
  _lazyfleet_done || return 1
  if (( $#o_D )) && [[ -n $br ]]; then
    _lazyfleet_step "Deleting local branch $br"
    git -C $repo branch -q -D $br
    _lazyfleet_done || rc=1
  fi
  if _lazyfleet_tmux has-session -t "=$s" 2>/dev/null; then
    # last: this may kill the shell we are running in
    _lazyfleet_step "Closing tmux session $s"
    print -u2
    _lazyfleet_tmux kill-session -t "=$s"
  fi
  return rc
}

# lazyfleet pull [worktree] — fast-forward it to its upstream (never merges)
_lazyfleet_pull() {
  local p br out
  if [[ -n $1 ]]; then
    _lazyfleet_resolve $1 || { _lazyfleet_err "no unique worktree for '$1' ($REPLY matches)"; return 1 }
    p=$REPLY
  else
    p=$(git rev-parse --show-toplevel 2>/dev/null) || { _lazyfleet_err 'usage: lazyfleet pull <worktree>'; return 1 }
  fi
  br=$(git -C $p branch --show-current 2>/dev/null)
  [[ -n $br ]] || { _lazyfleet_err "${p/#$HOME/~} is not on a branch"; return 1 }
  _lazyfleet_step "Pulling $br in ${p/#$HOME/~}"
  # git's own output only when it fails: it would land after the "… "
  out=$(git -C $p pull -q --ff-only 2>&1)
  _lazyfleet_done || { print -ru2 -- $out; return 1 }
}

# REPLY=dir of the TUI's background pulls: a file per worktree being pulled
# (its path with / as %), and <that>.err with the output of a failed one
_lazyfleet_pulldir() {
  _lazyfleet_tmpdir 2>/dev/null || return 1
  REPLY+=/pull
  [[ -d $REPLY ]] || mkdir -m 700 $REPLY 2>/dev/null
}

# Send fzf action $1 to the TUI's fzf, through its --listen socket ($FZF_SOCK)
_lazyfleet_fzfpost() {
  setopt local_options no_multibyte  # Content-Length counts bytes
  local fd r
  [[ -S $FZF_SOCK ]] || return 1
  zmodload zsh/net/socket || return 1
  zsocket $FZF_SOCK 2>/dev/null || return 1
  fd=$REPLY
  print -rn -- "POST / HTTP/1.1"$'\r\n'"Host: lazyfleet"$'\r\n'"Content-Length: $#1"$'\r\n\r\n'"$1" >&$fd
  read -r -t 5 r <&$fd
  exec {fd}>&-
  [[ $r == 'HTTP/1.1 200'* ]]
}

# Progress for slow steps, on stderr: "msg… " now, then "done"/"failed" by the
# status of the command run in between
_lazyfleet_step() { print -nu2 -- "$1… " }
_lazyfleet_done() {
  local rc=$?
  (( rc )) && print -u2 failed || print -u2 done
  return rc
}

# --- TUI --------------------------------------------------------------------

# fzf exits with an action ("open"/"new" + path); outside tmux we come back
# here when the attached session ends or is detached
# _lazyfleet_ui [-w (start in the Windows view)] [query]
_lazyfleet_ui() {
  local -a o_w
  zparseopts -D -E w=o_w
  local bin=${(q)LAZYFLEET_DIR}/bin/lazyfleet k q=$1 out view=${o_w:+windows} rows sel i rc
  local -a binds lines start
  # coming back from a session, the first load puts the cursor on the row we
  # left (sel: its path or window target); this file hands that over once
  _lazyfleet_footers
  _lazyfleet_ui_label; local label=$REPLY
  _lazyfleet_tmpdir || return 1
  local -x LAZYFLEET_POSFILE=$REPLY/pos.$$
  # background jobs (pull) send fzf actions here; unix socket paths are
  # limited to 103 bytes; without it p pulls in the foreground
  local sock=$REPLY/fzf.$$.sock
  (( $#sock < 104 )) && binds+=(--listen=$sock) || sock=
  # start on the Windows view when tmux has any (unless given a query)
  [[ -z $view && -z $q && -n $(_lazyfleet_tmux list-windows -a -F x 2>/dev/null) ]] && view=windows
  # Query changes emitted by a transform are ignored by fzf, so the
  # view-switching keys reset the input with directly chained actions.
  local reset="+clear-query+hide-input+rebind($_LAZYFLEET_LETTERS)"
  for k in / n d p e g o r a c C R q; do binds+=(--bind "${k}:transform:$bin _key {1} {2}"); done
  for k in enter tab esc w; do binds+=(--bind "${k}:transform($bin _key {1} {2})$reset"); done
  binds+=(--bind "load:transform:$bin _loaded")
  while :; do
    if [[ $view == windows ]]; then
      start=(--list-label ' Windows ' --footer "$_LAZYFLEET_FOOTER_WIN" --preview-window $_LAZYFLEET_PW_WIN)
    else
      start=(--list-label ' Worktrees · loading… ' --footer "$_LAZYFLEET_FOOTER_WT" --preview-window $_LAZYFLEET_PW)
    fi
    [[ -n $q ]] && start+=(--bind "start:show-input+unbind($_LAZYFLEET_LETTERS)")
    if [[ $view == windows ]]; then rows=$(_lazyfleet_winrows); else rows=$(_lazyfleet_rows); fi
    rm -f $LAZYFLEET_POSFILE
    if [[ -n $sel ]]; then
      lines=(${(f)rows})
      k=$'\t'  # $'\t' isn't expanded inside the subscript
      i=${lines[(i)*$k${(b)sel}$k*]}
      (( i <= $#lines )) && print $i >$LAZYFLEET_POSFILE
    fi
    out=$(print -r -- $rows |
      fzf --ansi --style full --layout reverse --no-input --no-sort \
      --delimiter '\t' --with-nth 3 --query "$q" \
      --border-label "$label" --preview-label ' Details ' \
      --with-shell "${commands[zsh]:-/bin/zsh} -c" \
      --preview "$bin _preview -f {1} {2}" --pointer '▌' --gutter ' ' --info inline-right \
      --bind 'j:down,k:up' $start $binds)
    rc=$?
    [[ -n $sock ]] && rm -f $sock
    (( rc )) && return 0
    q= sel=
    lines=(${(f)out})
    case $lines[1] in
      (open) view= sel=$lines[2]; _lazyfleet_open_path $sel || _lazyfleet_pause ;;
      (new) view=; _lazyfleet_ui_new $lines[2] || continue
            sel=$REPLY; _lazyfleet_open_path $sel ;;
      (edit|lazygit) view= sel=$lines[2]; _lazyfleet_handoff $lines[1] $sel || _lazyfleet_pause ;;
      (window) view=windows sel=$lines[2]; _lazyfleet_open_window $sel || _lazyfleet_pause ;;
      (*) rm -f $LAZYFLEET_POSFILE; return 0 ;;
    esac
    [[ -n $TMUX ]] && return 0
  done
}

# The Worktrees view loads in two steps, tracked in the list label: plain
# rows first ("· loading…"), then _lazyfleet_loaded swaps in rows with git
# status ("· checking status…"). Repo names and paths never go into the
# action text itself (a ")" in one would end the action and could add
# others): fzf hands them over through {2} and $FZF_LIST_LABEL.
# Worktrees view of all repos; -r: filtered to the current row's repo;
# -l: keeping the label's filter
_lazyfleet_wtload() {
  case $1 in
    (-r) REPLY="transform-list-label($bin _wtlabel loading {2})+reload($bin _rows -L)" ;;
    (-l) REPLY="transform-list-label($bin _wtlabel loading)+reload($bin _rows -L)" ;;
    (*) REPLY="change-list-label( Worktrees · loading… )+reload($bin _rows)" ;;
  esac
}

# REPLY=repo name filter of the Worktrees view's list label ("" for all)
_lazyfleet_labelrepo() {
  local base=${${${FZF_LIST_LABEL# }% }% · *}
  [[ $base == 'Worktrees: '* ]] && REPLY=${base#Worktrees: } || REPLY=
}

# Print the Worktrees list label for stage $1 (loading, checking, done),
# filtered to repo path $2's name, else to the current label's filter
_lazyfleet_wtlabel() {
  local name stage
  if [[ -n $2 ]]; then name=${2:t}; else _lazyfleet_labelrepo; name=$REPLY; fi
  case $1 in
    (loading) stage=' · loading…' ;;
    (checking) stage=' · checking status…' ;;
  esac
  print -r -- " Worktrees${name:+: $name}$stage "
}

# fzf load event: move to the row handed over in $LAZYFLEET_POSFILE (once),
# and after the plain worktree rows, fetch the ones with git status
_lazyfleet_loaded() {
  local bin=${(q)LAZYFLEET_DIR}/bin/lazyfleet lbl=${${FZF_LIST_LABEL# }% }
  local -a acts
  if [[ -n $LAZYFLEET_POSFILE && -s $LAZYFLEET_POSFILE ]]; then
    acts+=("pos($(<$LAZYFLEET_POSFILE))")
    rm -f $LAZYFLEET_POSFILE
  fi
  case $lbl in
    (Worktrees*' · loading…') acts+=("transform-list-label($bin _wtlabel checking)+reload-sync($bin _rows -s -L)") ;;
    (Worktrees*' · checking status…') acts+=("transform-list-label($bin _wtlabel done)") ;;
  esac
  (( $#acts )) && print -r -- ${(j:+:)acts}
}

# Key dispatcher: prints fzf actions. Args: row kind, row path.
_lazyfleet_key() {
  _lazyfleet_footers
  # the row's path is passed on as {2}, never as text in the actions
  local bin=${(q)LAZYFLEET_DIR}/bin/lazyfleet kind=$1 p=$2
  local lbl=${${${FZF_LIST_LABEL# }% }% · *} rl foot=$_LAZYFLEET_FOOTER_WT out wt
  local win="change-list-label( Windows )+change-footer($_LAZYFLEET_FOOTER_WIN)+change-preview-window($_LAZYFLEET_PW_WIN)+reload($bin _winrows)+first"
  local pw="change-preview-window($_LAZYFLEET_PW)"
  _lazyfleet_wtload; wt=$REPLY
  case $lbl in
    (Repos) rl="reload($bin _reporows)"; foot=$_LAZYFLEET_FOOTER_REPO ;;
    (Windows) rl="reload($bin _winrows)"; foot=$_LAZYFLEET_FOOTER_WIN ;;
    ('Worktrees: '*) _lazyfleet_wtload -l; rl=$REPLY ;;
    (*) rl=$wt ;;
  esac
  case $FZF_KEY in
    (/) print -r -- "show-input+unbind($_LAZYFLEET_LETTERS)" ;;
    (esc)
      [[ $FZF_INPUT_STATE == hidden ]] && print abort ;;
    (q) print abort ;;
    (c)
      # the row's project; the Windows view has none, so the settings
      if [[ $kind == [wr] && -n $p ]]; then print -r -- "execute($bin config {2})+$rl"
      else print -r -- "execute($bin config)+$rl"; fi ;;
    (C) print -r -- "execute($bin config)+$rl" ;;
    (r|R) print -r -- "$rl+change-footer($foot)" ;;
    (tab)
      case $lbl in
        (Repos) print -r -- $win ;;
        (Windows) print -r -- "change-footer($_LAZYFLEET_FOOTER_WT)+$pw+$wt+first" ;;
        (*) print -r -- "change-list-label( Repos )+change-footer($_LAZYFLEET_FOOTER_REPO)+reload($bin _reporows)+first" ;;
      esac ;;
    (w) print -r -- $win ;;
    (enter)
      [[ -n $p ]] || return 0
      if [[ $kind == r ]]; then
        _lazyfleet_wtload -r
        print -r -- "change-footer($_LAZYFLEET_FOOTER_WT)+$REPLY+first"
      elif [[ $kind == t ]]; then
        print -r -- "become(printf '%s\\n' window {2})"
      else
        print -r -- "become(printf '%s\\n' open {2})"
      fi ;;
    (n) [[ $kind == t ]] || print -r -- "become(printf '%s\\n' new {2})" ;;
    (a)
      # a filtered list would hide the new repo
      if [[ $lbl == Repos ]]; then print -r -- "execute($bin _ui_add)+$rl"
      else print -r -- "execute($bin _ui_add)+change-footer($_LAZYFLEET_FOOTER_WT)+$pw+$wt"; fi ;;
    (d)
      [[ -n $p ]] || return 0
      case $kind in
        (r) print -r -- "execute($bin _ui_forget {2})+$rl" ;;
        (t) print -r -- "execute($bin _ui_killwin {2})+$rl" ;;
        (*) print -r -- "execute($bin _ui_rm {2})+$rl" ;;
      esac ;;
    (e|g)
      # the editor or lazygit, in a window of the worktree's session
      [[ $kind == w && -n $p ]] || return 0
      [[ $FZF_KEY == e ]] && print -r -- "become(printf '%s\\n' edit {2})" || print -r -- "become(printf '%s\\n' lazygit {2})" ;;
    (o)
      [[ $kind == w && -n $p ]] || return 0
      print -r -- "execute($bin _ui_openpr {2})" ;;
    (p)
      [[ $kind == w && -n $p ]] || return 0
      # in the background when fzf listens: the row shows ⟳ until it's done
      if [[ -n $FZF_SOCK ]]; then print -r -- "execute-silent($bin _ui_pull {2})+$rl"
      else print -r -- "execute($bin _ui_pull {2})+$rl"; fi ;;
  esac
}

# --- hand-off: other tools, in the worktree ---------------------------------
# The editor and lazygit run in a window of the worktree's own session (named
# "edit" and "lazygit"), which is created once and shown again when it exists.

# REPLY=the command line to run in the worktree for tool $1 (edit|lazygit)
_lazyfleet_tool() {
  emulate -L zsh
  local ed
  case $1 in
    (edit)
      ed=${VISUAL:-${EDITOR:-vi}}
      (( $+commands[${ed%% *}] )) || [[ ${ed%% *} == */* && -x ${ed%% *} ]] ||
        { _lazyfleet_err "editor '${ed%% *}' not found (set \$VISUAL or \$EDITOR)"; return 1 }
      REPLY="$ed ." ;;
    (lazygit)
      (( $+commands[lazygit] )) ||
        { _lazyfleet_err "lazygit is not installed (https://github.com/jesseduffield/lazygit)"; return 1 }
      REPLY=lazygit ;;
    (*) _lazyfleet_err "unknown tool: $1"; return 1 ;;
  esac
}

# Show tool $1 (edit|lazygit) for worktree $2: in its window, started when
# there is none, then switch to it (inside tmux) or attach (outside)
_lazyfleet_handoff() {
  emulate -L zsh
  local tool=$1 p=$2 cmd s id= line sep='@@lf@@'
  _lazyfleet_tool $tool || return 1
  cmd=$REPLY
  _lazyfleet_ensure $p || return 1
  s=$REPLY
  for line in ${(f)"$(_lazyfleet_tmux list-windows -t "=$s" -F "#{window_name}${sep}#{window_id}" 2>/dev/null)"}; do
    if [[ ${line%%$sep*} == $tool ]]; then id=${line##*$sep}; break; fi
  done
  if [[ -z $id ]]; then
    id=$(_lazyfleet_tmux new-window -d -P -F '#{window_id}' -t "=$s:" -c ${p:A} -n $tool "exec $cmd") ||
      { _lazyfleet_err "could not start $tool in session $s"; return 1 }
    # a tool that cannot start ends its window at once: give it a moment, so
    # that we can say so instead of switching to nothing
    zmodload zsh/zselect 2>/dev/null && zselect -t 20
  fi
  _lazyfleet_tmux select-window -t $id 2>/dev/null ||
    { _lazyfleet_err "$tool ended right away; run '${cmd% .}' in ${p/#$HOME/~} to see why"; return 1 }
  _lazyfleet_attach "=$s"
}

# Open URL $1 in a browser: $BROWSER, else the system's opener
_lazyfleet_browser() {
  emulate -L zsh
  if [[ -n $BROWSER ]]; then
    command ${=BROWSER} $1
  elif [[ $OSTYPE == darwin* ]] && (( $+commands[open] )); then
    command open $1 &>/dev/null
  elif (( $+commands[xdg-open] )); then
    command xdg-open $1 &>/dev/null
  else
    _lazyfleet_err "no browser found (set \$BROWSER)"; return 1
  fi
}

# Open the pull request of worktree $1 in the browser, from what the pull
# request marks know (so it needs the same: gh, a GitHub origin, pr_status on).
_lazyfleet_openpr() {
  emulate -L zsh
  local p=$1 repo slug br url
  local -A prs
  local -a f
  _lazyfleet_toplevel $p && repo=$REPLY || { _lazyfleet_err "not a git worktree: $p"; return 1 }
  br=$(git -C $p branch --show-current 2>/dev/null)
  [[ -n $br ]] || { _lazyfleet_err "${p/#$HOME/~} is not on a branch"; return 1 }
  if _lazyfleet_pr_enabled && _lazyfleet_ghslug $repo; then
    slug=$REPLY
  else
    _lazyfleet_err "pull requests need gh, a GitHub origin, and pr_status on"; return 1
  fi
  _lazyfleet_pr_read $slug >/dev/null ||
    { _lazyfleet_err "no pull request data yet (it is fetched in the background): try again in a moment"; return 1 }
  f=("${(@ps:\t:)prs[${slug:l}:$br]}")
  url=$f[4]
  [[ -n $url ]] || { _lazyfleet_err "no pull request known for $br"; return 1 }
  # the cache is data, and this goes to a program: only GitHub pull request links
  [[ $url =~ '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$' ]] ||
    { _lazyfleet_err "not a GitHub pull request link: ${url//[[:cntrl:]]/ }"; return 1 }
  _lazyfleet_browser $url
}

_lazyfleet_ui_openpr() { _lazyfleet_openpr $1 || _lazyfleet_pause }

# Prompt for a branch and create its worktree; REPLY=its path
_lazyfleet_ui_new() {
  local repo br
  if ! { [[ -n $1 ]] && _lazyfleet_toplevel $1 } && ! _lazyfleet_toplevel; then
    print 'Add a repo first (a).'; _lazyfleet_pause; return 1
  fi
  repo=$REPLY
  _lazyfleet_branches $repo | _lazyfleet_pick "New worktree in ${repo:t}" 'branch> ' || return 1
  br=$REPLY
  REPLY=$(_lazyfleet_new -q --no-open -r $repo $br) || { _lazyfleet_pause; return 1 }
}

_lazyfleet_ui_add() {
  _lazyfleet_findrepos | _lazyfleet_pick 'Add repo' 'repo> ' || return 0
  _lazyfleet_add ${REPLY/#\~/$HOME} >/dev/null || _lazyfleet_pause
}

# lazyfleet config [repo] — edit the global settings, or a repo's own config
# file, in $VISUAL/$EDITOR; a missing file starts as a commented example
_lazyfleet_config() {
  local f repo
  if [[ -n $1 ]]; then
    _lazyfleet_find_repo $1 || _lazyfleet_toplevel $1 || { _lazyfleet_err "unknown repo: $1"; return 1 }
    repo=$REPLY
    _lazyfleet_projconf $repo; f=$REPLY
  else
    _lazyfleet_regfile; f=${REPLY:h}/config
  fi
  if [[ ! -e $f ]]; then
    mkdir -p ${f:h}
    if [[ -n $repo ]]; then
      {
        print -r -- "# lazyfleet config for ${repo:t} (${repo/#$HOME/~}). Lines starting with # are ignored."
        print -r -- "# Used for new worktrees; wins over the repo's .lazyfleet. Indent lines to continue a value."
        print -r -- "# copy=.env .env.local"
        print -r -- "# setup="
        print -r -- "#   npm ci"
        if [[ -r $repo/.lazyfleet ]]; then
          print -r -- "#"
          print -r -- "# The repo's .lazyfleet currently has:"
          print -rl -- "#   "${^${(f)"$(<$repo/.lazyfleet)"}}
        fi
      } >$f
    else
      cat >$f <<'EOF'
# lazyfleet settings. Lines starting with # are ignored.
# Env vars LAZYFLEET_SEARCH, LAZYFLEET_SEARCH_DEPTH, LAZYFLEET_WORKTREES and
# LAZYFLEET_STATUS_BRANCH win over these. Per-project copy=/setup= go in
# projects/<name>.conf (press c on a project in lazyfleet).
# search=~/Projects ~/work
# search_depth=4
# worktrees=~/.lazyfleet/worktrees
# status_branch=off   (no branch in the tmux status bar of new sessions)
# update_check=off     (don't look for a newer release once a day; LAZYFLEET_UPDATE_CHECK)
# agent_icons=off      (no ✻ Claude Code / ✦ Copilot CLI / π omp marks on worktrees and windows; LAZYFLEET_AGENT_ICONS)
# pr_status=off        (no pull request / CI marks on worktrees; LAZYFLEET_PR_STATUS)
EOF
    fi
  fi
  ${=${VISUAL:-${EDITOR:-vi}}} $f
}

_lazyfleet_ui_killwin() {
  print -rn -- "Kill window ${1#=}? [y/N] "
  read -q </dev/tty && _lazyfleet_tmux kill-window -t "$1"
  print
}

_lazyfleet_ui_forget() {
  print -n "Forget ${1:t}? (files are kept) [y/N] "
  read -q </dev/tty && _lazyfleet_forget $1
  print
}

# REPLY=warning when branch $2 (seen from worktree $1) has commits that no
# remote has (as of the last fetch), else empty
_lazyfleet_unpushed() {
  local n s
  n=$(git -C $1 rev-list --count refs/heads/$2 --not --remotes 2>/dev/null) || n=0
  REPLY=
  (( n )) || return 0
  (( n == 1 )) && s="1 commit" || s="$n commits"
  if git -C $1 show-ref -q --verify refs/remotes/origin/$2; then
    REPLY="$s on $2 aren't on origin; deleting the branch drops them"
  else
    REPLY="$2 was never pushed; deleting it drops its $s"
  fi
  REPLY+=" (git reflog can still find them for a while)"
}

# Pull worktree $1; with $FZF_SOCK in a detached job that marks the row as
# pulling, then has fzf reload (and show git's output if it failed)
_lazyfleet_ui_pull() {
  [[ -n $FZF_SOCK ]] || { _lazyfleet_pull $1 || _lazyfleet_pause; return }
  _lazyfleet_pulldir || return 1
  local m=$REPLY/${1//\//%} bin=${(q)LAZYFLEET_DIR}/bin/lazyfleet
  [[ -e $m ]] && return 0  # already pulling
  : >$m
  {
    local out
    out=$(_lazyfleet_pull $1 2>&1) || print -r -- $out >$m.err
    rm -f $m
    _lazyfleet_fzfpost "transform($bin _pulled)"
  } </dev/null >/dev/null 2>&1 &!
}

# fzf actions once a background pull is done: show failed pulls, then reload
_lazyfleet_pulled() {
  local bin=${(q)LAZYFLEET_DIR}/bin/lazyfleet
  _lazyfleet_pulldir || return
  local -a errs=($REPLY/*.err(N))
  (( $#errs )) && print -rn -- "execute($bin _ui_pullfail)+"
  FZF_KEY=r _lazyfleet_key
}

_lazyfleet_ui_pullfail() {
  local e
  _lazyfleet_pulldir || return
  for e in $REPLY/*.err(N); do print -r -- "$(<$e)"; print; rm -f $e; done
  _lazyfleet_pause
}

_lazyfleet_ui_rm() {
  local br repo
  if _lazyfleet_toplevel $1 && [[ ${1:A} == ${REPLY:A} ]]; then
    repo=$REPLY
    print -rn -- "${1/#$HOME/~} is the repo itself, not a removable worktree. Forget ${repo:t} instead? (files are kept) [y/N] "
    read -q </dev/tty && _lazyfleet_forget $repo
    print
    return
  fi
  br=$(git -C $1 branch --show-current 2>/dev/null)
  print -rn -- "Remove worktree ${1/#$HOME/~}? [y/N] "
  read -q </dev/tty || { print; return }
  print
  local -a flags ids
  local e
  _lazyfleet_containers_in $1
  if (( $#reply )); then
    print -r -- $'\e[33mWarning:\e[0m '"$#reply Docker container(s) from this worktree are running; their files can't be deleted until they stop:"
    for e in $reply; do e=${e#*$'\t'}; print -r -- "   ${e%%$'\t'*}"; ids+=(${e##*$'\t'}); done
    print -n "Stop them? [y/N] "
    if read -q </dev/tty; then
      print
      _lazyfleet_step "Stopping $#ids container(s)"
      docker stop $ids >/dev/null
      _lazyfleet_done || _lazyfleet_pause
    else
      print
    fi
  fi
  if [[ -n $br ]]; then
    _lazyfleet_unpushed $1 $br
    [[ -n $REPLY ]] && print -r -- $'\e[33mWarning:\e[0m '$REPLY
    print -rn -- "Also delete local branch $br? (the remote is untouched) [y/N] "
    read -q </dev/tty && flags+=(-D)
    print
  fi
  _lazyfleet_rm $flags $1 || _lazyfleet_pause
}

_lazyfleet_help() {
  local v= tag
  _lazyfleet_version_label && v=" $REPLY"
  print -r -- "lazyfleet$v — git worktrees, each in its own tmux session"
  cat <<'EOF'

  lazyfleet                      open the TUI
  lazyfleet add [path]           register a repo
  lazyfleet forget [repo]        unregister a repo
  lazyfleet repos                list registered repos
  lazyfleet ls                   list worktrees with status
  lazyfleet new <branch> [-r repo] [-b base] [--no-open]
  lazyfleet new --pr <number> | --issue <number> [-r repo] [-b base] [--no-open]
                                 the same, for a pull request's branch or a branch named after an issue (needs gh)
                                 create a worktree (+ .lazyfleet copy/setup) and open it
  lazyfleet open [worktree]      attach/switch to a worktree's session
  lazyfleet rm [worktree] [-f] [-D]
                                 remove a worktree (-f: even if dirty, locked or with agents running,
                                 -D: delete its local branch too)
  lazyfleet pull [worktree]      fast-forward a worktree to its upstream
  lazyfleet prune [-n] [-y] [--keep-branches] [--no-fetch] [-r repo | --all]
                                 remove worktrees whose branch is merged (-n: only list them)
  lazyfleet windows              open the TUI on all tmux windows (enter switches)
  lazyfleet config [repo]        edit the settings, or a repo's copy=/setup= file, in $EDITOR
  lazyfleet status               tmux status segment: sessions whose agent waits (!) or is done (✓)
  lazyfleet hooks [install|uninstall|status]
                                 let Claude Code report what it is doing (edits settings.json,
                                 keeps a backup)
  lazyfleet doctor               check that zsh, git, tmux and fzf (and gh) are there and recent enough
  lazyfleet version              show the installed version
  lazyfleet update [--install]   look for a newer release now (otherwise once a day); --install installs it

.lazyfleet (repo root, key=value; indent lines to continue a value):
  setup=…  copy=file1 file2
~/.config/lazyfleet/projects/<repo>.conf: the same keys, for one repo (wins)
~/.config/lazyfleet/config: search=dirs  search_depth=n  worktrees=dir  status_branch=off  update_check=off  agent_icons=off  agent_notify=off  pr_status=off
EOF
  if _lazyfleet_update_available; then
    tag=$REPLY; _lazyfleet_update_hint
    print -r -- "
Update available: $tag. Update: $REPLY"
  fi
}

# lazyfleet version
_lazyfleet_versioncmd() {
  if _lazyfleet_version_label; then print -r -- "lazyfleet $REPLY"
  else print -r -- "lazyfleet (unknown version: not installed from a release)"; fi
}

# --- update check ------------------------------------------------------------
# At most once a day, in the background, ask GitHub for the latest release and
# cache the answer; the TUI shows what is cached, so starting it never waits
# for the network. Only a copy that knows its version (a VERSION file, written
# by install.sh) checks: a git checkout does not.
# Turn it off with update_check=off in the config file or LAZYFLEET_UPDATE_CHECK=off.

zmodload -F zsh/datetime p:EPOCHSECONDS
autoload -Uz is-at-least

# REPLY=the version of this copy (X.Y.Z), if it knows one
_lazyfleet_version() {
  local v
  [[ -r $LAZYFLEET_DIR/VERSION ]] || return 1
  v=${${$(<$LAZYFLEET_DIR/VERSION)#v}//[[:space:]]/}
  [[ $v == <->.<->.<-> ]] || return 1
  REPLY=$v
}

# is version $1 newer than version $2? (plain X.Y.Z both)
_lazyfleet_newer() { ! is-at-least $1 $2 }

_lazyfleet_update_enabled() {
  _lazyfleet_version || return 1
  (( $+commands[curl] )) || return 1
  _lazyfleet_setting update_check LAZYFLEET_UPDATE_CHECK on
  [[ ${REPLY:l} != (off|no|false|0) ]]
}

# REPLY=the cache file: "<epoch> <tag>", the tag empty when the lookup failed
_lazyfleet_update_cache() { REPLY=${XDG_CACHE_HOME:-$HOME/.cache}/lazyfleet/latest-release }

# Look up the latest release (GitHub redirects /releases/latest to its tag,
# which spares the API rate limit) and write it to cache file $1
_lazyfleet_update_fetch() {
  local f=$1 url tag= tmp
  url=$(command curl -fsSL --max-time 10 -o /dev/null -w '%{url_effective}' \
    ${LAZYFLEET_RELEASES_URL:-https://github.com/mmolhoek/lazyfleet/releases}/latest 2>/dev/null) && tag=${url:t}
  [[ $tag == v<->.<->.<-> ]] || tag=
  mkdir -p ${f:h} && tmp=$f.$$ && print -r -- "$EPOCHSECONDS $tag" >$tmp && mv -f $tmp $f
}

# Refresh the cache in the background, unless it is under a day old
_lazyfleet_update_refresh() {
  emulate -L zsh
  local f stamp= tag=
  _lazyfleet_update_enabled || return 0
  _lazyfleet_update_cache; f=$REPLY
  [[ -r $f ]] && read -r stamp tag <$f
  [[ $stamp == <-> ]] && (( EPOCHSECONDS - stamp < 86400 )) && return 0
  ( _lazyfleet_update_fetch $f ) &>/dev/null &!
  return 0
}

# REPLY=the cached latest version (vX.Y.Z), if newer than this copy
_lazyfleet_update_available() {
  emulate -L zsh
  local f stamp= tag= cur
  _lazyfleet_update_enabled || return 1
  _lazyfleet_version; cur=$REPLY
  _lazyfleet_update_cache; f=$REPLY
  [[ -r $f ]] && read -r stamp tag <$f
  if [[ $tag == v<->.<->.<-> ]] && _lazyfleet_newer ${tag#v} $cur; then
    REPLY=$tag; return 0
  fi
  REPLY=; return 1
}

# REPLY=how to update this copy, by how it was installed
_lazyfleet_update_hint() {
  if [[ -e $LAZYFLEET_DIR/INSTALLER ]]; then
    REPLY='curl -fsSL https://raw.githubusercontent.com/mmolhoek/lazyfleet/main/install.sh | sh'
  else
    REPLY="see ${LAZYFLEET_RELEASES_URL:-https://github.com/mmolhoek/lazyfleet/releases}"
  fi
}

# Tell (on stderr) that an update is available, and how to get it
_lazyfleet_update_notice() {
  emulate -L zsh
  local tag cur
  _lazyfleet_update_available || return 0
  tag=$REPLY; _lazyfleet_version; cur=$REPLY
  _lazyfleet_update_hint
  print -ru2 -- "lazyfleet $tag is available (you have v$cur). Update: $REPLY"
}

# lazyfleet update [--install] — look for a newer release right now, in the
# foreground, whatever the daily cache or update_check say; the answer
# refreshes the cache. With --install, also install it.
_lazyfleet_update() {
  emulate -L zsh
  local cur tag= stamp= f install=
  case ${1-} in
    ('') ;;
    (--install|-i) install=1 ;;
    (*) _lazyfleet_err "usage: lazyfleet update [--install]"; return 1 ;;
  esac
  (( $# > 1 )) && { _lazyfleet_err "usage: lazyfleet update [--install]"; return 1 }
  _lazyfleet_version || {
    _lazyfleet_err "this copy does not know its version (no VERSION file); a git checkout updates with git pull"
    return 1
  }
  cur=$REPLY
  (( $+commands[curl] )) || { _lazyfleet_err "curl is required to look for updates"; return 1 }
  _lazyfleet_update_cache; f=$REPLY
  _lazyfleet_update_fetch $f
  [[ -r $f ]] && read -r stamp tag <$f
  if [[ -z $tag ]]; then
    _lazyfleet_err "could not find the latest release (offline, or none published yet)"
    return 1
  fi
  if ! _lazyfleet_newer ${tag#v} $cur; then
    print -r -- "lazyfleet v$cur is up to date."
    return 0
  fi
  if [[ -z $install ]]; then
    _lazyfleet_update_hint
    print -r -- "lazyfleet $tag is available (you have v$cur). Update: $REPLY"
    return 0
  fi
  _lazyfleet_update_install $tag $cur
}

# Install release $1 (the current one is $2) by running that release's own
# install.sh on this installation. Only a copy that install.sh put here can be
# replaced this way.
_lazyfleet_update_install() {
  emulate -L zsh
  local tag=$1 cur=$2 tmp url
  if [[ ! -e $LAZYFLEET_DIR/INSTALLER ]]; then
    _lazyfleet_update_hint
    _lazyfleet_err "this copy was not installed by install.sh, so it cannot update itself. $tag is available (you have v$cur): $REPLY"
    return 1
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lazyfleet-update.XXXXXX") || { _lazyfleet_err "could not make a temporary directory"; return 1 }
  {
    url=${LAZYFLEET_INSTALLER_URL:-https://raw.githubusercontent.com/mmolhoek/lazyfleet/$tag/install.sh}
    print -r -- "Installing lazyfleet $tag (you have v$cur)..."
    if ! command curl -fsSL --max-time 30 -o $tmp/install.sh $url 2>/dev/null || [[ ! -s $tmp/install.sh ]]; then
      _lazyfleet_err "could not download the installer for $tag"
      return 1
    fi
    # that release's installer, aimed at this directory and exactly that tag
    env -u LAZYFLEET_SHA256 LAZYFLEET_VERSION=$tag LAZYFLEET_INSTALL_DIR=$LAZYFLEET_DIR sh $tmp/install.sh
  } always {
    rm -rf $tmp
  }
}

# REPLY=the TUI's border label, which points out an available update
_lazyfleet_ui_label() {
  if _lazyfleet_update_available; then REPLY=" lazyfleet · $REPLY available "
  else REPLY=' lazyfleet '; fi
}

# REPLY=what to call this copy: "v1.2.3" for a release, "feat/x (branch)" for
# an install of a branch (install.sh records the branch name as the version).
# Fails when this copy does not know. Only plain name characters are shown,
# since the VERSION file's content ends up on the terminal.
_lazyfleet_version_label() {
  emulate -L zsh
  local v
  if _lazyfleet_version; then REPLY=v$REPLY; return 0; fi
  [[ -r $LAZYFLEET_DIR/VERSION ]] || return 1
  v=${$(<$LAZYFLEET_DIR/VERSION)//[[:space:]]/}
  [[ $v =~ '^[A-Za-z0-9._/-]+$' ]] || return 1
  REPLY="$v (branch)"
}

# REPLY=the version line for the TUI footers: "lazyfleet v1.2.3", followed by
# "update available: v1.2.4" when the cache knows a newer release. Fails when
# this copy does not know its version.
_lazyfleet_version_line() {
  emulate -L zsh
  local label tag
  _lazyfleet_version_label || return 1
  label=$REPLY
  if _lazyfleet_update_available; then
    tag=$REPLY; REPLY="lazyfleet $label · update available: $tag"
  else
    REPLY="lazyfleet $label"
  fi
}

# Put the version line under each TUI footer. The footers are globals that the
# TUI and its key handler (a separate process) both use, so both call this;
# doing it twice in one process changes nothing.
typeset -g _LAZYFLEET_FOOTERS_DONE=
_lazyfleet_footers() {
  [[ -n $_LAZYFLEET_FOOTERS_DONE ]] && return 0
  _LAZYFLEET_FOOTERS_DONE=1
  _lazyfleet_version_line || return 0
  _LAZYFLEET_FOOTER_WT+=$'\n'$REPLY
  _LAZYFLEET_FOOTER_REPO+=$'\n'$REPLY
  _LAZYFLEET_FOOTER_WIN+=$'\n'$REPLY
}

_lazyfleet_interactive() { [[ -t 1 && -t 2 ]] }

# The TUI, plus the update check when run by a person: refresh the cache before
# it starts, and print the notice after it ends, when it would not be wiped
_lazyfleet_ui_checked() {
  local rc
  _lazyfleet_interactive && _lazyfleet_update_refresh
  _lazyfleet_ui "$@"; rc=$?
  _lazyfleet_interactive && _lazyfleet_update_notice
  return $rc
}

# The command itself always runs bin/lazyfleet, which loads this file from
# disk: a shell that sourced an older version would otherwise keep running it
lazyfleet() { $LAZYFLEET_DIR/bin/lazyfleet "$@" }

# --- doctor ------------------------------------------------------------------
# lazyfleet doctor: is everything lazyfleet relies on here, and recent enough?
# Every finding is "ok", "warn" (something is reduced, or may not work) or
# "FAIL" (lazyfleet cannot work). The exit status is 1 when anything failed.
# Only fzf's minimum is known to be hard (--style); the zsh, git and tmux
# minimums are conservative, so an older one only warns.

typeset -g _LAZYFLEET_MIN_ZSH=5.1     # zmodload -F
typeset -g _LAZYFLEET_MIN_GIT=2.17    # git worktree remove
typeset -g _LAZYFLEET_MIN_TMUX=3.0
typeset -g _LAZYFLEET_MIN_FZF=0.58    # first fzf with --style (install.sh has the same number)
typeset -gi _lazyfleet_doctor_fails=0 _lazyfleet_doctor_warns=0

# level (ok|warn|fail), text, and an optional fix to suggest
_lazyfleet_doctor_report() {
  emulate -L zsh
  local level=$1 text=${2//[[:cntrl:]]/ } fix=${3//[[:cntrl:]]/ } tag col= end=
  case $level in
    (ok)   tag='ok  '; col=$'\e[32m' ;;
    (warn) tag='warn'; col=$'\e[33m'; (( ++_lazyfleet_doctor_warns )) ;;
    (fail) tag='FAIL'; col=$'\e[31m'; (( ++_lazyfleet_doctor_fails )) ;;
  esac
  if [[ -t 1 ]]; then end=$'\e[0m'; else col=; fi
  print -r -- "  ${col}${tag}${end}  $text"
  if [[ -n $fix ]]; then print -r -- "        try: $fix"; fi
}

# Judge a tool by the first version number in $2 (what its --version printed):
# name, version text, minimum, level to report when too old, fix
_lazyfleet_doctor_judge() {
  emulate -L zsh
  local name=$1 min=$3 old=$4 fix=$5 v
  if [[ $2 =~ '[0-9]+(\.[0-9]+)*' ]]; then
    v=$MATCH
  else
    _lazyfleet_doctor_report warn "$name: cannot tell the version (it printed '${2[1,40]}')"
    return
  fi
  if is-at-least $min $v; then
    _lazyfleet_doctor_report ok "$name $v"
  else
    _lazyfleet_doctor_report $old "$name $v is too old: lazyfleet needs $min or newer" $fix
  fi
}

# A tool that must be there: name, minimum, level when too old, fix, and the
# command that prints its version
_lazyfleet_doctor_need() {
  emulate -L zsh
  local name=$1 min=$2 old=$3 fix=$4 out missing=
  shift 4
  # LAZYFLEET_TMUX may be a path, which is not in the command table
  if [[ $1 == */* ]]; then
    [[ -x $1 ]] || missing=1
  elif (( ! $+commands[$1] )); then
    missing=1
  fi
  if [[ -n $missing ]]; then
    _lazyfleet_doctor_report fail "$name is not installed" $fix
    return
  fi
  out=$("$@" 2>&1 </dev/null)
  _lazyfleet_doctor_judge $name ${out%%$'\n'*} $min $old $fix
}

_lazyfleet_doctor_install_hint() { REPLY="macOS: brew install $1    Debian/Ubuntu: sudo apt install $1" }

# the tools around the features that can do without them
_lazyfleet_doctor_optional() {
  emulate -L zsh
  if (( $+commands[curl] )); then
    _lazyfleet_doctor_report ok "curl (update check)"
  else
    _lazyfleet_doctor_report warn "curl is not installed: no update check" "sudo apt install curl / brew install curl"
  fi
  _lazyfleet_setting pr_status LAZYFLEET_PR_STATUS on
  if [[ ${REPLY:l} == (off|no|false|0) ]]; then
    _lazyfleet_doctor_report ok "pull request marks are off (pr_status=off)"
  elif (( ! $+commands[gh] )); then
    _lazyfleet_doctor_report warn "gh is not installed: no pull request marks" "https://cli.github.com"
  elif ! gh auth token >/dev/null 2>&1 </dev/null; then
    _lazyfleet_doctor_report warn "gh has no login: no pull request marks" "gh auth login"
  else
    _lazyfleet_doctor_report ok "gh is logged in (pull request marks)"
  fi
  # agent state needs Claude Code's hooks, which are installed with jq
  if (( $+commands[claude] )); then
    if (( ! $+commands[jq] )); then
      _lazyfleet_doctor_report warn "jq is not installed: Claude Code hooks cannot be set up" "sudo apt install jq / brew install jq"
    elif _lazyfleet_hooks status >/dev/null 2>&1; then
      _lazyfleet_doctor_report ok "Claude Code hooks are installed (agent state)"
    else
      _lazyfleet_doctor_report warn "Claude Code hooks are not installed: agents show no state" "lazyfleet hooks install"
    fi
  fi
}

# the registry: repositories that have gone away
_lazyfleet_doctor_repos() {
  emulate -L zsh
  local r
  local -a repos gone
  _lazyfleet_repos
  repos=($reply)
  for r in $repos; do [[ -d $r ]] || gone+=($r); done
  if (( ! $#repos )); then
    _lazyfleet_doctor_report ok "no repositories registered yet" "lazyfleet add [path]"
    return
  fi
  if (( $#repos == 1 )); then
    _lazyfleet_doctor_report ok "1 repository registered"
  else
    _lazyfleet_doctor_report ok "$#repos repositories registered"
  fi
  for r in ${gone[1,5]}; do
    _lazyfleet_doctor_report warn "$r no longer exists" "lazyfleet forget ${r:t}"
  done
  if (( $#gone > 5 )); then _lazyfleet_doctor_report warn "and $(( $#gone - 5 )) more missing repositories"; fi
}

_lazyfleet_doctor() {
  emulate -L zsh
  _lazyfleet_doctor_fails=0 _lazyfleet_doctor_warns=0
  print -r -- "lazyfleet doctor"
  if _lazyfleet_version_label; then
    _lazyfleet_doctor_report ok "lazyfleet ${REPLY} in $LAZYFLEET_DIR"
  else
    _lazyfleet_doctor_report ok "lazyfleet from a checkout in $LAZYFLEET_DIR (no version, no update check)"
  fi
  _lazyfleet_doctor_judge zsh $ZSH_VERSION $_LAZYFLEET_MIN_ZSH warn ""
  _lazyfleet_doctor_install_hint git;  _lazyfleet_doctor_need git  $_LAZYFLEET_MIN_GIT  warn $REPLY git --version
  _lazyfleet_doctor_install_hint tmux; _lazyfleet_doctor_need tmux $_LAZYFLEET_MIN_TMUX warn $REPLY ${=LAZYFLEET_TMUX:-tmux} -V
  _lazyfleet_doctor_install_hint fzf;  _lazyfleet_doctor_need fzf  $_LAZYFLEET_MIN_FZF  fail $REPLY fzf --version
  _lazyfleet_doctor_optional
  _lazyfleet_doctor_repos
  print
  if (( _lazyfleet_doctor_fails )); then
    print -r -- "$_lazyfleet_doctor_fails problem(s), $_lazyfleet_doctor_warns warning(s)."
  elif (( _lazyfleet_doctor_warns )); then
    print -r -- "No problems, $_lazyfleet_doctor_warns warning(s)."
  else
    print -r -- "All good."
  fi
  (( ! _lazyfleet_doctor_fails ))
}

# --- prune -------------------------------------------------------------------
# lazyfleet prune: remove the worktrees (and their local branches) whose work
# has been merged. Two things count as merged, and only these:
#   - GitHub says the branch's pull request was merged, and the worktree is at
#     exactly the commit that pull request ended with (so a squash merge works
#     and nothing done after it is lost);
#   - the branch's remote branch is gone (deleted after a merge) and every
#     commit of it is in the default branch.
# A merged worktree with uncommitted changes, a lock or running agents is
# listed, but left alone.

# Is the branch checked out in worktree $2 of repo $1 merged? $3 is the repo's
# GitHub owner/name (may be empty); the pull requests are in the caller's
# associative array prs (see _lazyfleet_pr_read). Returns 0 with REPLY=why when
# it is merged, 2 with REPLY=why when it looks merged but pruning it would lose
# commits, and 1 when it is not merged (or cannot be told).
_lazyfleet_merged() {
  emulate -L zsh
  local repo=$1 p=$2 slug=$3 br head def pr track note=
  local -a f
  br=$(git -C $p branch --show-current 2>/dev/null)
  [[ -n $br ]] || return 1
  head=$(git -C $p rev-parse HEAD 2>/dev/null) || return 1
  if [[ -n $slug ]]; then
    pr=${prs[${slug:l}:$br]-}
    f=("${(@ps:\t:)pr}")
    if [[ $f[2] == merged ]]; then
      if [[ -n $f[6] && $head == $f[6] ]]; then
        REPLY="pull request #$f[1] was merged"
        return 0
      fi
      note="pull request #$f[1] was merged, but $br is not at the commit it was merged at"
    fi
  fi
  track=$(git -C $repo for-each-ref --format='%(upstream:track)' refs/heads/$br 2>/dev/null)
  if [[ $track == '[gone]' ]]; then
    def=$(git -C $repo symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
    if [[ -n $def ]] && git -C $repo merge-base --is-ancestor $head $def 2>/dev/null; then
      REPLY="merged into $def, and its remote branch is gone"
      return 0
    fi
    [[ -n $note ]] || note="its remote branch is gone, but it has commits ${def:-the default branch} does not"
  fi
  [[ -n $note ]] || return 1
  REPLY=$note
  return 2
}

# lazyfleet prune [-n] [-y] [--keep-branches] [--no-fetch] [-r repo | --all]
_lazyfleet_prune() {
  emulate -L zsh
  local -a o_n o_y o_k o_f o_r o_a
  zparseopts -D -E -F n=o_n -dry-run=o_n y=o_y -yes=o_y -keep-branches=o_k -no-fetch=o_f r:=o_r -all=o_a || return 1
  local usage='usage: lazyfleet prune [-n] [-y] [--keep-branches] [--no-fetch] [-r repo | --all]'
  (( $# )) && { _lazyfleet_err $usage; return 1 }
  (( $#o_r && $#o_a )) && { _lazyfleet_err "give -r or --all, not both"; return 1 }
  local repo p br s e why rc cur ans
  local -a repos todo skipped flags
  local -A prs
  local slug n_other
  if (( $#o_a )); then
    _lazyfleet_repos; repos=($reply)
  elif (( $#o_r )); then
    _lazyfleet_find_repo $o_r[2] || _lazyfleet_toplevel $o_r[2] || { _lazyfleet_err "unknown repo: $o_r[2]"; return 1 }
    repos=($REPLY)
  else
    _lazyfleet_toplevel || { _lazyfleet_err 'not in a repo; pass -r <repo> or --all'; return 1 }
    repos=($REPLY)
  fi
  (( $#repos )) || { print -r -- "No repositories registered."; return 0 }
  # the tmux session we are in goes last: closing it ends this command
  [[ -n $TMUX ]] && cur=$(_lazyfleet_tmux display-message -p '#S' 2>/dev/null)
  local -a first last brs
  for repo in $repos; do
    [[ -d $repo ]] || continue
    n_other=0
    if (( ! $#o_f )); then
      _lazyfleet_step "Updating ${repo:t} (git fetch --prune)"
      git -C $repo fetch -q --prune origin 2>/dev/null
      _lazyfleet_done || print -ru2 -- "  (offline? going by what is known)"
    fi
    slug=; prs=()
    if _lazyfleet_pr_enabled && _lazyfleet_ghslug $repo; then
      slug=$REPLY
      brs=()
      _lazyfleet_worktrees $repo
      for e in $reply; do brs+=(${${e#*$'\t'}%$'\t'*}); done
      _lazyfleet_pr_cachefile $slug && _lazyfleet_pr_fetch $slug $REPLY $brs >/dev/null 2>&1
      _lazyfleet_pr_read $slug >/dev/null 2>&1
    fi
    _lazyfleet_worktrees $repo
    for e in $reply; do
      p=${e%%$'\t'*}; [[ ${e##*$'\t'} == 1 ]] && continue      # the main worktree stays
      rc=0; _lazyfleet_merged $repo $p $slug; rc=$?
      why=$REPLY
      br=$(git -C $p branch --show-current 2>/dev/null)
      if (( rc == 1 )); then (( n_other++ )); continue; fi
      if (( rc == 0 )); then
        if _lazyfleet_locked $p; then rc=2 why="$why, but it is $REPLY"
        elif [[ -n $(git -C $p --no-optional-locks status --porcelain 2>/dev/null) ]]; then rc=2 why="$why, but it has uncommitted changes"
        else
          _lazyfleet_session $repo $p 0; s=$REPLY
          _lazyfleet_session_agents $s
          if (( $#reply )); then rc=2 why="$why, but agents are running in $s"; fi
        fi
      fi
      if (( rc == 0 )); then
        if [[ -n $cur && $s == $cur ]]; then last+=("$p"$'\t'"$br"$'\t'"$why"); else first+=("$p"$'\t'"$br"$'\t'"$why"); fi
      else
        skipped+=("${repo:t}"$'\t'"$br"$'\t'"$why")
      fi
    done
  done
  todo=($first $last)
  for e in $todo; do
    print -r -- "  prune  ${${${e#*$'\t'}%%$'\t'*}//[[:cntrl:]]/ }  —  ${${e##*$'\t'}//[[:cntrl:]]/ }"
  done
  for e in $skipped; do
    print -r -- "  keep   ${${${e#*$'\t'}%%$'\t'*}//[[:cntrl:]]/ }  —  ${${e##*$'\t'}//[[:cntrl:]]/ }"
  done
  if (( ! $#todo )); then
    print -r -- "Nothing to prune."
    return 0
  fi
  if (( $#o_n )); then
    print -r -- "$#todo worktree(s) would be removed (dry run)."
    return 0
  fi
  if (( ! $#o_y )); then
    [[ -t 0 ]] || { _lazyfleet_err "not on a terminal: use -y to go ahead"; return 1 }
    ans="Remove $#todo worktree(s)"
    (( $#o_k )) && ans+=" (keeping their branches)"
    print -rn -- "$ans? [y/N] "
    read -q </dev/tty || { print; return 1 }
    print
  fi
  flags=(); (( $#o_k )) || flags=(-D)
  local done_n=0 failed_n=0
  for e in $todo; do
    if _lazyfleet_rm $flags ${e%%$'\t'*}; then (( done_n++ )); else (( failed_n++ )); fi
  done
  print -r -- "Removed $done_n worktree(s)${${failed_n:#0}:+, $failed_n failed}."
  (( ! failed_n ))
}

_lazyfleet_main() {
  emulate -L zsh
  local cmd=$1
  (( $# )) && shift
  case $cmd in
    ('') _lazyfleet_ui_checked ;;
    (add|forget|new|open|rm|pull|prune|ls|config|update|status|hooks|doctor) _lazyfleet_$cmd "$@" ;;
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
