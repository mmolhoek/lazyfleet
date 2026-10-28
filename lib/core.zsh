# lazyfleet: Plumbing: tmux, temp files, the repo registry, worktrees and session names.
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.

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
# Wait for one key on the terminal itself (not stdin, which is not the keyboard
# under fzf's execute) and succeed for y. A function of its own so that a test
# can stand in for the keyboard.
_lazyfleet_readkey() { read -q </dev/tty }

# Ask "$1 [y/N] " and succeed for y
_lazyfleet_ask() {
  local rc
  print -rn -- "$1 [y/N] "
  _lazyfleet_readkey; rc=$?
  print
  return rc
}

# _lazyfleet_ask for a command: with $2, a command that does not run on a
# terminal (a script) fails with that message instead of asking
_lazyfleet_confirm() {
  [[ -z $2 || -t 0 ]] || { _lazyfleet_err $2; return 1 }
  _lazyfleet_ask $1
}

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

# A worktree entry (from _lazyfleet_worktrees) is "path<TAB>branch<TAB>ismain".
# REPLY=its path, its branch (or "(detached)"), or 1 for the repo's main worktree
_lazyfleet_wt_path() { REPLY=${1%%$'\t'*} }
_lazyfleet_wt_branch() { REPLY=${${1#*$'\t'}%$'\t'*} }
_lazyfleet_wt_ismain() { REPLY=${1##*$'\t'} }

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
  _lazyfleet_sortby _lazyfleet_wt_branch
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
      # git 2.48+ can write it relative to its own dir (worktree.useRelativePaths)
      [[ $wt == /* ]] || wt=${${:-$d/$wt}:A}
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

# REPLY=the branch checked out in worktree $1; fails when there is none (a
# detached HEAD, or not a repo)
_lazyfleet_branch_of() {
  REPLY=$(git -C $1 branch --show-current 2>/dev/null)
  [[ -n $REPLY ]]
}

# The same, saying so (on stderr) when there is no branch
_lazyfleet_need_branch() {
  _lazyfleet_branch_of $1 || { _lazyfleet_err "${1/#$HOME/~} is not on a branch"; return 1 }
}

# REPLY=tmux session name for worktree $2 of repo $1 ($3=1 if main worktree)
_lazyfleet_session() {
  REPLY=${1:t}
  [[ $3 == 1 ]] || REPLY+=/${2:t}
  REPLY=${REPLY//[.:]/-}
}
