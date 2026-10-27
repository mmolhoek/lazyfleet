# lazyfleet: lazyfleet prune: remove the worktrees whose work has been merged.
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.

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
