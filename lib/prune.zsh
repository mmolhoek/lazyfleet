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
  _lazyfleet_branch_of $p || return 1
  br=$REPLY
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

# Bring repo $1 up to date before it is judged: git fetch --prune (unless $2 is
# not empty, for --no-fetch) and the GitHub pull request data. Sets the
# caller's slug (the repo's owner/name, or empty) and fills its array prs.
_lazyfleet_prune_refresh() {
  emulate -L zsh
  local repo=$1 e
  local -a brs
  if [[ -z $2 ]]; then
    _lazyfleet_step "Updating ${repo:t} (git fetch --prune)"
    git -C $repo fetch -q --prune origin 2>/dev/null
    _lazyfleet_done || print -ru2 -- "  (offline? going by what is known)"
  fi
  slug=; prs=()
  if _lazyfleet_pr_enabled && _lazyfleet_ghslug $repo; then
    slug=$REPLY
    _lazyfleet_worktrees $repo
    for e in $reply; do _lazyfleet_wt_branch $e; brs+=($REPLY); done
    _lazyfleet_pr_cachefile $slug && _lazyfleet_pr_fetch $slug $REPLY $brs >/dev/null 2>&1
    _lazyfleet_pr_read $slug >/dev/null 2>&1
  fi
}

# Judge worktree $2 of repo $1 ($3: the repo's GitHub owner/name, if any; the
# caller's prs holds its pull requests). Returns 0 and REPLY=why when it is to
# go, 2 and REPLY=why when it is merged but is left alone (a lock, uncommitted
# changes, running agents, or commits that would be lost), and 1 when it is not
# merged.
_lazyfleet_prune_judge() {
  emulate -L zsh
  local repo=$1 p=$2 slug=$3 why rc s
  _lazyfleet_merged $repo $p $slug; rc=$?
  why=$REPLY
  (( rc == 0 )) || { REPLY=$why; return rc }
  if _lazyfleet_locked $p; then
    why="$why, but it is $REPLY"
  elif [[ -n $(git -C $p --no-optional-locks status --porcelain 2>/dev/null) ]]; then
    why="$why, but it has uncommitted changes"
  else
    _lazyfleet_session $repo $p 0; s=$REPLY
    _lazyfleet_session_agents $s
    if (( $#reply )); then
      why="$why, but agents are running in $s"
    else
      REPLY=$why; return 0
    fi
  fi
  REPLY=$why
  return 2
}

# Print the line for entry $2 ("x<TAB>branch<TAB>why") under the word $1. The
# branch and the reason end up on the terminal, so no control characters.
_lazyfleet_prune_line() {
  local e=$2 br why
  br=${${e#*$'\t'}%%$'\t'*} why=${e##*$'\t'}
  print -r -- "  ${(r:5:)1}  ${br//[[:cntrl:]]/ }  —  ${why//[[:cntrl:]]/ }"
}

# lazyfleet prune [-n] [-y] [--keep-branches] [--no-fetch] [-r repo | --all]
_lazyfleet_prune() {
  emulate -L zsh
  local -a o_n o_y o_k o_f o_r o_a
  zparseopts -D -E -F n=o_n -dry-run=o_n y=o_y -yes=o_y -keep-branches=o_k -no-fetch=o_f r:=o_r -all=o_a || return 1
  local usage='usage: lazyfleet prune [-n] [-y] [--keep-branches] [--no-fetch] [-r repo | --all]'
  (( $# )) && { _lazyfleet_err $usage; return 1 }
  (( $#o_r && $#o_a )) && { _lazyfleet_err "give -r or --all, not both"; return 1 }
  local repo p br e why rc cur ans slug
  local -a repos todo skipped flags first last
  local -A prs
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
  for repo in $repos; do
    [[ -d $repo ]] || continue
    _lazyfleet_prune_refresh $repo ${o_f:+1}
    _lazyfleet_worktrees $repo
    for e in $reply; do
      _lazyfleet_wt_ismain $e; [[ $REPLY == 1 ]] && continue      # the main worktree stays
      _lazyfleet_wt_path $e; p=$REPLY
      _lazyfleet_prune_judge $repo $p $slug; rc=$?
      why=$REPLY
      (( rc == 1 )) && continue
      _lazyfleet_branch_of $p; br=$REPLY
      if (( rc == 0 )); then
        _lazyfleet_session $repo $p 0
        if [[ -n $cur && $REPLY == $cur ]]; then last+=("$p"$'\t'"$br"$'\t'"$why"); else first+=("$p"$'\t'"$br"$'\t'"$why"); fi
      else
        skipped+=("${repo:t}"$'\t'"$br"$'\t'"$why")
      fi
    done
  done
  todo=($first $last)
  for e in $todo; do _lazyfleet_prune_line prune $e; done
  for e in $skipped; do _lazyfleet_prune_line keep $e; done
  if (( ! $#todo )); then
    print -r -- "Nothing to prune."
    return 0
  fi
  if (( $#o_n )); then
    print -r -- "$#todo worktree(s) would be removed (dry run)."
    return 0
  fi
  if (( ! $#o_y )); then
    ans="Remove $#todo worktree(s)"
    (( $#o_k )) && ans+=" (keeping their branches)"
    _lazyfleet_confirm "$ans?" "not on a terminal: use -y to go ahead" || return 1
  fi
  flags=(); (( $#o_k )) || flags=(-D)
  local done_n=0 failed_n=0
  for e in $todo; do
    if _lazyfleet_rm $flags ${e%%$'\t'*}; then (( done_n++ )); else (( failed_n++ )); fi
  done
  print -r -- "Removed $done_n worktree(s)${${failed_n:#0}:+, $failed_n failed}."
  (( ! failed_n ))
}
