# lazyfleet: Stacked branches: which branch a branch is stacked on, the marks and previews that show it, and restack.
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.
#
# A stacked branch records its parent in the repo's git config:
#   branch.<name>.lazyfleetParent     the branch it sits on
#   branch.<name>.lazyfleetParentRev  the parent's commit it was last based on
# git renames that section along with the branch (git branch -m) and drops it
# with the branch (git branch -D), so nothing else has to keep it in step.
#
# Inside this file a stack "entry" is "branch<TAB>parent<TAB>rev<TAB>stale":
# stale is 0 (up to date), 1 (the parent has moved on: restack) or 2 (the
# parent is gone, typically merged and deleted: restack onto the default
# branch). The functions that only look at entries have no side effects, and
# take the entries as their last arguments.

# --- entries: no git, no side effects ----------------------------------------

# reply=("branch<TAB>parent<TAB>rev" ...), by branch, from the lines of
# `git config --get-regexp '^branch\..*\.lazyfleetparent(rev)?$'` in $@. A
# branch name may hold dots, so the name is what lies between "branch." and
# the last dot.
_lazyfleet_stack_parse() {
  local line key val b
  local -A par rev
  for line in "$@"; do
    key=${line%% *}
    [[ $key == "$line" ]] && val= || val=${line#* }
    b=${${key#branch.}%.*}
    case ${key##*.} in
      (lazyfleetparent) par[$b]=$val ;;
      (lazyfleetparentrev) rev[$b]=$val ;;
    esac
  done
  reply=()
  for b in ${(ko)par}; do
    [[ -n $par[$b] ]] && reply+=("$b"$'\t'"$par[$b]"$'\t'"$rev[$b]")
  done
}

# REPLY=0 when the parent's tip $1 is the commit $2 the branch was last based
# on, 1 when it moved on, 2 when there is no tip (the parent is gone)
_lazyfleet_stack_staleness() {
  if [[ -z $1 ]]; then REPLY=2
  elif [[ $1 == $2 ]]; then REPLY=0
  else REPLY=1; fi
}

# _lazyfleet_stack_chain branch entries...
# reply=(the branches from the bottom of the stack up to the branch itself),
# REPLY=the branch the bottom one sits on (main, say). Fails, with an empty
# reply, when the branch has no parent recorded.
_lazyfleet_stack_chain() {
  local b=$1 e
  local -A par seen
  shift
  for e in "$@"; do par[${e%%$'\t'*}]=${${e#*$'\t'}%%$'\t'*}; done
  reply=() REPLY=
  [[ -n $par[$b] ]] || return 1
  # (seen: a loop can only come from a hand-edited config; never follow one)
  while [[ -n $par[$b] && -z $seen[$b] ]]; do
    seen[$b]=1
    reply=($b $reply)
    b=$par[$b]
  done
  REPLY=$b
}

# _lazyfleet_stack_kids branch entries...
# reply=(the branches stacked directly on the branch, by name)
_lazyfleet_stack_kids() {
  local p=$1 e
  shift
  reply=()
  for e in "$@"; do
    [[ ${${e#*$'\t'}%%$'\t'*} == "$p" ]] && reply+=(${e%%$'\t'*})
  done
  reply=(${(o)reply})
}

# _lazyfleet_stack_below branch entries...
# reply=(every branch stacked on the branch, directly or not, parents before
# their children: the order to restack them in)
_lazyfleet_stack_below() {
  local b
  local -a todo=($1) out
  local -A seen=([$1]=1)
  shift
  while (( $#todo )); do
    b=$todo[1]; shift todo
    _lazyfleet_stack_kids $b "$@"
    for b in $reply; do
      [[ -n $seen[$b] ]] && continue
      seen[$b]=1; out+=($b); todo+=($b)
    done
  done
  reply=($out)
}

# _lazyfleet_stack_pos branch trunk entries...
# REPLY="position/height": how far up its stack the branch is (1 for the
# bottom) and how high that stack gets. Fails when there is no stack worth a
# mark: no parent recorded, or a single branch on the default branch $2.
_lazyfleet_stack_pos() {
  local b=$1 trunk=$2 d pos top base
  shift 2
  _lazyfleet_stack_chain $b "$@" || return 1
  pos=$#reply top=$#reply base=$REPLY
  _lazyfleet_stack_below $reply[1] "$@"
  for d in $reply; do
    _lazyfleet_stack_chain $d "$@"
    (( $#reply > top )) && top=$#reply
  done
  (( top > 1 )) || [[ $base != "$trunk" ]] || return 1
  REPLY=$pos/$top
}

# _lazyfleet_stack_mark [-p (plain)] position/height stale
# REPLY=the mark on a worktree's row: ▲2/3, plus ⟲ when it needs a restack
# ("stack 2/3 restack" when plain)
_lazyfleet_stack_mark() {
  local c=$'\e[35m' w=$'\e[33m' off=$'\e[0m'
  if [[ $1 == -p ]]; then
    shift
    REPLY="stack $1"
    (( $2 )) && REPLY+=' restack'
    return 0
  fi
  REPLY="$c▲$1$off"
  (( $2 )) && REPLY+=" $w⟲$off"
  return 0
}

# _lazyfleet_stack_tree branch entries...
# reply=(the lines of the branch's whole stack, for a preview: the branch it
# all sits on, then each stacked branch under its parent). The branch itself
# is bold with a ←; one that needs a restack says so.
_lazyfleet_stack_tree() {
  local cur=$1 b d e line
  local -a todo out
  local -A stale
  shift
  for e in "$@"; do stale[${e%%$'\t'*}]=${e##*$'\t'}; done
  _lazyfleet_stack_chain $cur "$@" || { reply=(); return 1 }
  out=("   $REPLY")
  todo=("0 $reply[1]")
  while (( $#todo )); do
    d=${todo[1]%% *} b=${todo[1]#* }
    shift todo
    _lazyfleet_stack_line $cur $b $d "$stale[$b]"
    out+=($REPLY)
    _lazyfleet_stack_kids $b "$@"
    todo=(${reply/#/$(( d + 1 )) } $todo)
  done
  reply=($out)
}

# REPLY=one line of _lazyfleet_stack_tree: branch $2 at depth $3 with
# staleness $4, where $1 is the branch the preview is for
_lazyfleet_stack_line() {
  local cur=$1 b=$2 d=$3 st=$4 name=$2
  [[ $b == "$cur" ]] && name=$'\e[1m'$b$'\e[0m ←'
  REPLY="   ${(l:d*2:)}└ $name"
  case $st in
    (1) REPLY+=$' \e[33m⟲ restack\e[0m' ;;
    (2) REPLY+=$' \e[33m⟲ parent gone\e[0m' ;;
  esac
}

# --- reading and writing git ---------------------------------------------------

# reply=(the stack entries of repo $1, by branch): two git calls, and only the
# first when nothing is stacked
_lazyfleet_stack_load() {
  local e line
  local -a f out
  local -A tip
  _lazyfleet_stack_parse ${(f)"$(git -C $1 config --get-regexp '^branch\..*\.lazyfleetparent(rev)?$' 2>/dev/null)"}
  (( $#reply )) || return 0
  for line in ${(f)"$(git -C $1 for-each-ref --format='%(refname) %(objectname)' refs/heads)"}; do
    line=${line#refs/heads/}
    tip[${line% *}]=${line##* }
  done
  for e in $reply; do
    f=("${(@ps:\t:)e}")
    _lazyfleet_stack_staleness "$tip[$f[2]]" "$f[3]"
    out+=("$e"$'\t'$REPLY)
  done
  reply=($out)
}

# REPLY=the repo $1's default branch as a local branch: origin/HEAD's, else
# main, else master. Fails when there is none of those.
_lazyfleet_stack_trunk() {
  local b
  b=$(git -C $1 symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
  for b in ${b#origin/} main master; do
    [[ -n $b ]] && git -C $1 show-ref -q --verify refs/heads/$b && { REPLY=$b; return 0 }
  done
  REPLY=
  return 1
}

# Succeed when $2 is a local branch of repo $1
_lazyfleet_stack_isbranch() { git -C $1 show-ref -q --verify refs/heads/$2 }

# _lazyfleet_stack_link repo branch parent [rev]
# Stack the branch on the parent, as based on the parent's commit rev (by
# default where the two meet). Refuses a branch on itself and a loop.
_lazyfleet_stack_link() {
  local repo=$1 br=$2 par=$3 rev=$4
  [[ $br != "$par" ]] || { _lazyfleet_err "$br cannot be stacked on itself"; return 1 }
  _lazyfleet_stack_isbranch $repo $br || { _lazyfleet_err "no local branch $br"; return 1 }
  _lazyfleet_stack_isbranch $repo $par ||
    { _lazyfleet_err "no local branch $par (a stack sits on a local branch)"; return 1 }
  _lazyfleet_stack_load $repo
  _lazyfleet_stack_chain $par $reply && (( ${reply[(Ie)$br]} )) &&
    { _lazyfleet_err "$par is stacked on $br already: that would make a loop"; return 1 }
  [[ -n $rev ]] || rev=$(git -C $repo merge-base refs/heads/$par refs/heads/$br 2>/dev/null) ||
    { _lazyfleet_err "$br and $par have no commit in common"; return 1 }
  git -C $repo config branch.$br.lazyfleetParent $par &&
    git -C $repo config branch.$br.lazyfleetParentRev $rev
}

# Offer to stack branch $2 of repo $1 on the default branch, when a stack is
# being built on it and it is stacked on nothing itself: then r keeps the
# whole stack on the latest default branch, and its row shows ▲1/n too.
# Asked, never done unasked: a long-lived branch (develop, a release branch)
# must not be rebased onto the default branch.
_lazyfleet_stack_offer_root() {
  local repo=$1 br=$2 trunk
  _lazyfleet_stack_trunk $repo || return 0
  trunk=$REPLY
  [[ $br != "$trunk" ]] || return 0
  git -C $repo config --get branch.$br.lazyfleetParent >/dev/null && return 0
  _lazyfleet_ask "$br is stacked on nothing itself. Stack it on $trunk too, so r keeps the stack on the latest $trunk?" || return 0
  _lazyfleet_stack_link $repo $br $trunk || _lazyfleet_pause
  return 0
}

# Forget what branch $2 of repo $1 is stacked on; fails when it was not
_lazyfleet_stack_unlink() {
  git -C $1 config --get branch.$2.lazyfleetParent >/dev/null ||
    { _lazyfleet_err "$2 is not stacked on anything"; return 1 }
  git -C $1 config --unset branch.$2.lazyfleetParent
  git -C $1 config --unset branch.$2.lazyfleetParentRev
  return 0
}

# REPLY=the worktree that has branch $2 of repo $1 checked out
_lazyfleet_stack_wt() {
  local e
  _lazyfleet_worktrees $1
  for e in $reply; do
    _lazyfleet_wt_branch $e
    [[ $REPLY == "$2" ]] && { _lazyfleet_wt_path $e; return 0 }
  done
  _lazyfleet_err "$2 has no worktree to rebase it in: lazyfleet new $2"
  return 1
}

# --- restack -----------------------------------------------------------------

# _lazyfleet_stack_restack_one repo branch parent rev [-i]
# Rebase the branch, in its own worktree, onto its parent: the commits after
# rev (the parent's commit it was last based on) go on top of the parent's
# tip. A parent that is gone is replaced by the default branch, for good. A
# rebase of the branch that stopped earlier is finished first. A branch
# already on its parent's tip only has rev brought up to date. With -i, a
# conflict is resolved here, file by file (_lazyfleet_stack_finish).
_lazyfleet_stack_restack_one() {
  local repo=$1 br=$2 par=$3 rev=$4 i=$5 wt= tip own
  _lazyfleet_stack_onto $repo $br $par || return 1
  par=$REPLY
  _lazyfleet_stack_wt $repo $br 2>/dev/null && wt=$REPLY
  # its own commits, the ones a rebase replays (after the base it was last on,
  # not the parent's tip, which may be restacked already); the branch ref only
  # moves once a rebase is done, so this counts what it had
  _lazyfleet_stack_upstream $repo $br $par "$rev"
  own=$(git -C $repo rev-list --count $REPLY..refs/heads/$br)
  if [[ -n $wt ]] && _lazyfleet_stack_rebasing $wt; then
    tip=$(git -C $repo rev-parse refs/heads/$br)
    _lazyfleet_stack_finish $br $wt "$i" && _lazyfleet_stack_landed $repo $br $tip || return 1
  elif ! git -C $repo merge-base --is-ancestor refs/heads/$par refs/heads/$br; then
    _lazyfleet_stack_rebase $repo $br $par "$rev" "$wt" "$i" || return 1
  fi
  # (rev becomes where the two meet: the parent's tip, unless it moved on meanwhile)
  _lazyfleet_stack_link $repo $br $par || return 1
  _lazyfleet_stack_kept $repo $br $par $own "$wt"
}

# _lazyfleet_stack_kept repo branch parent own worktree
# Fail, saying what to do, when the branch had commits of its own (own: how
# many) before it was restacked and has none now. Their changes are gone:
# nearly always a conflict resolved to the parent's side only. Restacking the
# branches above it now would only bring the loss up to them as conflicts,
# so the restack stops here; a restack again goes on (when it was meant).
_lazyfleet_stack_kept() {
  local repo=$1 br=$2 par=$3 own=$4 wt=$5
  (( own )) || return 0
  (( $(git -C $repo rev-list --count refs/heads/$par..refs/heads/$br) )) && return 0
  print -ru2 -- "lazyfleet: $br has no commits of its own any more (it had $own): their changes are gone."
  print -ru2 -- "  Most likely a conflict was resolved to one side only (in lazygit, space picks one hunk; b picks both)."
  print -ru2 -- "  To undo it: git -C ${${wt:-$repo}/#$HOME/~} reset --hard '$br@{1}', then restack again."
  print -ru2 -- "  If they were meant to go (they are in $par already), restack again to go on."
  return 1
}

# _lazyfleet_stack_landed repo branch tip
# Succeed when the branch moved from commit tip, as a finished rebase moves
# it (git moves the branch only at the end); else the rebase was aborted (in
# lazygit, say), which leaves it where it was: say so
_lazyfleet_stack_landed() {
  [[ $(git -C $1 rev-parse refs/heads/$2) != $3 ]] && return 0
  print -ru2 -- "lazyfleet: the rebase of $2 was aborted; the branch is as it was"
  return 1
}

# REPLY=what branch $2 of repo $1 goes onto: its parent $3, or the default
# branch when the parent is gone (saying so)
_lazyfleet_stack_onto() {
  local why=gone
  if _lazyfleet_stack_isbranch $1 $3; then
    _lazyfleet_stack_merged $1 $3 || { REPLY=$3; return 0 }
    why=merged
  fi
  _lazyfleet_stack_trunk $1 ||
    { _lazyfleet_err "$2: its parent $3 is $why, and there is no main or master to move it onto"; return 1 }
  print -ru2 -- "lazyfleet: $2: its parent $3 is $why, so it moves onto $REPLY"
}

# --- origin, and parents merged on GitHub --------------------------------------

# Before a restack: bring repo $1's view of origin up to date (git fetch
# --prune; offline, that is said and then ignored), and its default branch
# along with it when that is a plain fast-forward
_lazyfleet_stack_sync() {
  git -C $1 remote get-url origin >/dev/null 2>&1 || return 0
  if ! git -C $1 fetch -q --prune origin 2>/dev/null; then
    print -ru2 -- "lazyfleet: could not fetch from origin; going on with what is known here"
    return 0
  fi
  _lazyfleet_stack_fftrunk $1
  return 0
}

# Fast-forward repo $1's default branch to origin's, when it is behind and has
# nothing of its own: in the worktree that has it checked out (only when that
# has no changes), else the branch alone. Says so when it moved.
_lazyfleet_stack_fftrunk() {
  local repo=$1 trunk wt e
  _lazyfleet_stack_trunk $repo || return 0
  trunk=$REPLY
  git -C $repo show-ref -q --verify refs/remotes/origin/$trunk || return 0
  [[ $(git -C $repo rev-parse refs/heads/$trunk) != $(git -C $repo rev-parse refs/remotes/origin/$trunk) ]] || return 0
  git -C $repo merge-base --is-ancestor refs/heads/$trunk refs/remotes/origin/$trunk || return 0
  _lazyfleet_stack_wt $repo $trunk 2>/dev/null && wt=$REPLY
  if [[ -n $wt ]]; then
    [[ -z $(git -C $wt status --porcelain --untracked-files=no 2>/dev/null) ]] || return 0
    git -C $wt merge -q --ff-only refs/remotes/origin/$trunk 2>/dev/null || return 0
  else
    git -C $repo update-ref refs/heads/$trunk refs/remotes/origin/$trunk || return 0
  fi
  print -ru2 -- "lazyfleet: $trunk is brought up to date with origin"
}

# Succeed when branch $2 of repo $1 is merged: GitHub says its pull request
# was merged at the commit the branch is at (the pull request marks' cache, as
# prune has it); or, without GitHub, it was pushed, origin's branch is gone,
# and each of its commits is in origin's default branch
_lazyfleet_stack_merged() {
  local repo=$1 br=$2 slug trunk
  local -a f
  local -A prs
  if _lazyfleet_pr_enabled && _lazyfleet_ghslug $repo; then
    slug=$REPLY
    _lazyfleet_pr_read $slug >/dev/null 2>&1
    f=("${(@ps:	:)prs[${slug:l}:$br]}")
    [[ $f[2] == merged && -n $f[6] && $f[6] == $(git -C $repo rev-parse refs/heads/$br) ]] && return 0
  fi
  [[ $(git -C $repo config --get branch.$br.merge) == refs/heads/$br ]] || return 1
  git -C $repo show-ref -q --verify refs/remotes/origin/$br && return 1
  _lazyfleet_stack_trunk $repo || return 1
  trunk=$REPLY
  git -C $repo show-ref -q --verify refs/remotes/origin/$trunk || return 1
  [[ -z ${(M)${(f)"$(git -C $repo cherry refs/remotes/origin/$trunk refs/heads/$br 2>/dev/null)"}:#+*} ]]
}

# _lazyfleet_stack_rebase repo branch parent rev worktree [-i]
# Start the rebase of the branch in its worktree (none: say how to make one);
# when it stops on a conflict, go on with _lazyfleet_stack_finish
_lazyfleet_stack_rebase() {
  local repo=$1 br=$2 par=$3 rev=$4 wt=$5 i=$6 out tip
  [[ -n $wt ]] || { _lazyfleet_stack_wt $repo $br; return 1 }
  tip=$(git -C $repo rev-parse refs/heads/$br)
  [[ -z $(git -C $wt status --porcelain --untracked-files=no 2>/dev/null) ]] ||
    { _lazyfleet_err "$br has uncommitted changes in ${wt/#$HOME/~}: commit or stash them first"; return 1 }
  _lazyfleet_stack_upstream $repo $br $par "$rev"; rev=$REPLY
  _lazyfleet_step "Restacking $br onto $par"
  out=$(git -C $wt rebase -q --onto refs/heads/$par $rev 2>&1) && { print -u2 done; return 0 }
  _lazyfleet_stack_rebasing $wt || { print -u2 failed; [[ -n $out ]] && print -ru2 -- $out; return 1 }
  print -u2 conflict
  # git's own words say what conflicts (on a terminal the list of files does)
  [[ -n $out && -z $i ]] && print -ru2 -- $out
  _lazyfleet_stack_finish $br $wt "$i" && _lazyfleet_stack_landed $repo $br $tip
}

# REPLY=the commit after which branch $2 of repo $1 has its own commits, the
# ones to put on parent $3: the recorded rev $4, or where the branch and its
# parent meet when that is closer to the branch (a rev that fell behind) or
# when the rev is not in the branch's history at all (a rebase by hand)
_lazyfleet_stack_upstream() {
  local repo=$1 br=refs/heads/$2 par=refs/heads/$3 rev=$4 mb
  mb=$(git -C $repo merge-base $par $br)
  if [[ -z $rev ]] || ! git -C $repo merge-base --is-ancestor $rev $br 2>/dev/null ||
    git -C $repo merge-base --is-ancestor $rev $mb 2>/dev/null; then
    REPLY=$mb
  else
    REPLY=$rev
  fi
}

# Say how to go on after the rebase of branch $1 in worktree $2 stopped on a
# conflict (when there is no terminal to resolve it on)
_lazyfleet_stack_stopped() {
  print -ru2 -- "lazyfleet: the rebase of $1 stopped on a conflict in ${2/#$HOME/~}."
  print -ru2 -- "  Resolve the files there and git add them, then restack again: it continues the rebase."
  print -ru2 -- "  (In lazyfleet, r opens them for you to resolve.)"
}

# --- resolving a conflict ------------------------------------------------------

# Succeed when a rebase is under way in worktree $1 (stopped, since restack
# never leaves one running)
_lazyfleet_stack_rebasing() {
  local -a d
  d=(${(f)"$(git -C $1 rev-parse --path-format=absolute --git-path rebase-merge --git-path rebase-apply 2>/dev/null)"})
  [[ -n $d[1] && -d $d[1] ]] || [[ -n $d[2] && -d $d[2] ]]
}

# reply=(the files of worktree $1 that are in conflict)
_lazyfleet_stack_unmerged() {
  reply=(${(0)"$(git -C $1 diff -z --name-only --diff-filter=U 2>/dev/null)"})
}

# Succeed when file $1 still has conflict markers
_lazyfleet_stack_markers() {
  [[ -f $1 ]] && grep -qE '^(<{7}|>{7}|[|]{7})( |$)|^={7}$' -- $1 2>/dev/null
}

# _lazyfleet_stack_finish branch worktree [-i]
# Finish the stopped rebase of the branch: while files are in conflict, let
# the person resolve them (-i): in lazygit when it is installed, else one at
# a time in a list of their own; without -i say how and fail. Once none are,
# continue the rebase, which may stop on the next commit.
_lazyfleet_stack_finish() {
  local br=$1 wt=$2 i=$3 note=
  while _lazyfleet_stack_rebasing $wt; do
    _lazyfleet_stack_unmerged $wt
    if (( $#reply )); then
      [[ -n $i ]] || { _lazyfleet_stack_stopped $br $wt; return 1 }
      if _lazyfleet_stack_haslazygit; then
        _lazyfleet_stack_lazygit $br $wt || return 1
      else
        _lazyfleet_stack_resolve $br $wt "$note" $reply || return 1
      fi
      note=$REPLY
    else
      _lazyfleet_stack_continue $br $wt "$i" || return 1
      note=
    fi
  done
  return 0
}

# Succeed when lazygit is there to resolve conflicts in
_lazyfleet_stack_haslazygit() { (( $+commands[lazygit] )) }

# Run lazygit in worktree $2, on the terminal, to resolve the conflicts of
# the stopped rebase of branch $1 (it can continue or abort the rebase too).
# Once it quits, fail when files are still in conflict: the rebase is left
# for later. Anything else is for the caller to go on with.
_lazyfleet_stack_lazygit() {
  REPLY=
  ( cd $2 && _lazyfleet_stack_onterm lazygit )
  _lazyfleet_stack_rebasing $2 || return 0
  _lazyfleet_stack_unmerged $2
  (( $#reply )) || return 0
  _lazyfleet_stack_left $1 $2
  return 1
}

# Run command $@ on the terminal: stdin is not the keyboard under fzf's
# execute. Where there is no terminal (a test), as it is.
_lazyfleet_stack_onterm() {
  if { true </dev/tty } 2>/dev/null; then "$@" </dev/tty >/dev/tty
  else "$@"; fi
}

# Say that the rebase of branch $1 is left in worktree $2, and how to go on
_lazyfleet_stack_left() {
  print -ru2 -- "lazyfleet: the rebase of $1 is left in ${2/#$HOME/~}: press r (or restack) to go on with it"
}

# Continue the rebase of branch $1 in worktree $2 (git's message for each
# commit as it is), saying how it went. Fails only when it stopped for
# another reason than a conflict (which the caller goes on with).
_lazyfleet_stack_continue() {
  local out
  print -nu2 -- "Continuing the rebase of $1… "
  if out=$(GIT_EDITOR=true git -C $2 rebase --continue 2>&1); then
    print -u2 done; return 0
  fi
  _lazyfleet_stack_unmerged $2
  if (( $#reply )); then
    print -u2 'next conflict'
    [[ -n $3 ]] || print -ru2 -- $out
    return 0
  fi
  print -u2 failed
  print -ru2 -- $out
  return 1
}

# _lazyfleet_stack_resolve branch worktree note file...
# One round: pick a file in conflict and edit it (it is marked resolved once
# it has no markers left), abort the rebase, or leave it for later (fails).
# REPLY=a note for the next round.
_lazyfleet_stack_resolve() {
  local br=$1 wt=$2 note=$3
  shift 3
  _lazyfleet_stack_pickfile $br $wt "$note" "$@"
  case $reply[1] in
    (edit) _lazyfleet_stack_edit $wt "$reply[2]" ;;
    (abort)
      REPLY=
      _lazyfleet_ask "Abort the rebase of $br? (it goes back to how it was)" || return 0
      git -C $wt rebase --abort || return 1
      print -ru2 -- "lazyfleet: the rebase of $br is aborted; the branch is as it was"
      return 1 ;;
    (*) _lazyfleet_stack_left $br $wt; return 1 ;;
  esac
}

# Edit file $2 of worktree $1 in $VISUAL/$EDITOR, on the terminal; then
# mark it resolved, unless it still has conflict markers. REPLY=a note
# saying which happened.
_lazyfleet_stack_edit() {
  local wt=$1 f=$2 ed
  REPLY=
  [[ -n $f ]] || return 0
  _lazyfleet_tool edit || return 1
  ed=${REPLY% .}
  ( cd $wt && _lazyfleet_stack_onterm ${=ed} $f )
  if _lazyfleet_stack_markers $wt/$f; then
    REPLY="$f still has conflict markers"
  elif [[ -e $wt/$f ]]; then
    git -C $wt add -- $f && REPLY="$f resolved"
  else
    git -C $wt rm -q --cached -- $f && REPLY="$f resolved (deleted)"
  fi
  return 0
}

# _lazyfleet_stack_pickfile branch worktree note file...
# reply=(edit, abort or later, then the file picked): the files in conflict
# in fzf, each one's conflict in the preview, the note above them
_lazyfleet_stack_pickfile() {
  local br=$1 wt=$2 note=$3 head commit out rc
  local -a lines
  shift 3
  commit=$(git -C $wt log -1 --format='%h %s' REBASE_HEAD 2>/dev/null)
  (( $# == 1 )) && head='1 file in conflict' || head="$# files in conflict"
  head+=$'\n\e[2mapplying '${commit//[[:cntrl:]]/ }$'\e[0m'
  [[ -n $note ]] && head=$'\e[33m'${note//[[:cntrl:]]/ }$'\e[0m\n'$head
  out=$(print -rl -- "$@" | LAZYFLEET_RWT=$wt fzf --ansi --layout reverse --style full --no-sort --no-input \
    --list-label " Conflicts · $br " --preview-label ' Conflict ' --header $head \
    --footer $'↵ / e  edit the file (saved without markers: resolved)\na  abort the rebase   esc  later (r goes on)' \
    --with-shell "${commands[zsh]:-/bin/zsh} -c" \
    --preview 'git -C "$LAZYFLEET_RWT" -c color.diff=always diff -- {}' --preview-window right,60% \
    --pointer '▌' --gutter ' ' --expect a,e --bind 'j:down,k:up')
  rc=$?
  lines=("${(@f)out}")
  if (( rc )); then reply=(later '')
  elif [[ $lines[1] == a ]]; then reply=(abort '')
  else reply=(edit "$lines[2]"); fi
}

# reply=(repo, branch) of worktree $1 (default: the one we are in)
_lazyfleet_stack_here() {
  local p repo
  _lazyfleet_worktree_arg "$1" 'not in a worktree; name one' || return 1
  p=$REPLY
  _lazyfleet_toplevel $p || { _lazyfleet_err "not a git worktree: $p"; return 1 }
  repo=$REPLY
  _lazyfleet_stack_branch $p || { _lazyfleet_err "${p/#$HOME/~} is not on a branch"; return 1 }
  reply=($repo $REPLY)
}

# REPLY=the branch of worktree $1, also while a rebase of it is stopped
# (when HEAD is detached); fails when there is none
_lazyfleet_stack_branch() {
  local gd
  _lazyfleet_branch_of $1 && return 0
  gd=$(git -C $1 rev-parse --absolute-git-dir 2>/dev/null) || return 1
  _lazyfleet_head_dir $gd
  [[ $REPLY != '(detached)' ]]
}

# reply=(the branches to restack for branch $1, in order): its whole stack
# from the bottom, or, for a branch that is not stacked itself, the ones
# stacked on it. The entries follow.
_lazyfleet_stack_order() {
  local br=$1
  shift
  if _lazyfleet_stack_chain $br "$@"; then
    br=$reply[1]
    _lazyfleet_stack_below $br "$@"
    reply=($br $reply)
  else
    _lazyfleet_stack_below $br "$@"
  fi
  (( $#reply ))
}

# lazyfleet stack restack [-i] [worktree]: rebase each branch of the
# worktree's stack onto its parent, bottom up; stops at the first one that
# fails. -i: resolve a conflict here, file by file, instead of stopping.
_lazyfleet_stack_restack() {
  local repo br b e i= t=$'\t'  # ($'\t' isn't expanded inside a subscript)
  local -a entries f
  [[ $1 == -i ]] && { i=-i; shift }
  _lazyfleet_stack_here "$1" || return 1
  repo=$reply[1] br=$reply[2]
  _lazyfleet_stack_load $repo; entries=($reply)
  _lazyfleet_stack_order $br $entries ||
    { _lazyfleet_err "$br is not part of a stack (lazyfleet stack on <parent>)"; return 1 }
  local -a order=($reply)
  _lazyfleet_stack_sync $repo
  _lazyfleet_stack_load $repo; entries=($reply)
  for b in $order; do
    # a merged branch is done: the ones on it move on (_lazyfleet_stack_onto)
    if _lazyfleet_stack_merged $repo $b; then
      print -ru2 -- "lazyfleet: $b is merged: left as it is (lazyfleet prune removes it)"
      continue
    fi
    e=${entries[(r)${(b)b}$t*]}
    f=("${(@ps:\t:)e}")
    _lazyfleet_stack_restack_one $repo $b $f[2] "$f[3]" $i || return 1
  done
}

# --- what a branch changes ------------------------------------------------------

# REPLY=what branch $2 of repo $1 is compared with, to see its own changes:
# its parent when it is stacked (and the parent is there), else the default
# branch (origin's copy when there is one). Fails for the default branch.
_lazyfleet_diffbase() {
  local repo=$1 br=$2 par trunk
  par=$(git -C $repo config --get branch.$br.lazyfleetParent 2>/dev/null)
  if [[ -n $par ]] && _lazyfleet_stack_isbranch $repo $par; then REPLY=$par; return 0; fi
  _lazyfleet_stack_trunk $repo || return 1
  trunk=$REPLY
  [[ $br != "$trunk" ]] || return 1
  if git -C $repo show-ref -q --verify refs/remotes/origin/$trunk; then REPLY=origin/$trunk; else REPLY=$trunk; fi
}

# reply=(worktree $1, the branch's base: _lazyfleet_diffbase); says why not
_lazyfleet_diff_target() {
  local p repo br
  _lazyfleet_worktree_arg "$1" 'not in a worktree; name one' || return 1
  p=$REPLY
  _lazyfleet_toplevel $p || { _lazyfleet_err "not a git worktree: $p"; return 1 }
  repo=$REPLY
  _lazyfleet_stack_branch $p || { _lazyfleet_err "${p/#$HOME/~} is not on a branch"; return 1 }
  br=$REPLY
  _lazyfleet_diffbase $repo $br ||
    { _lazyfleet_err "$br is the default branch: there is nothing to compare it with"; return 1 }
  reply=($p $REPLY)
}

# The Details pane's commits of worktree $1: only the branch's own, since its
# base, the files they change, and their diff (the first
# _LAZYFLEET_DIFF_LINES lines: D shows all of it); fails when the branch has
# no base (the default branch), for the caller's plain log. Commits only (base...HEAD):
# a diff with the working tree can rewrite the index, which the preview, run
# all the time, must never do (git status above it shows what is uncommitted).
_lazyfleet_diff_preview() {
  local p=$1 repo br base n
  _lazyfleet_toplevel $p || return 1; repo=$REPLY
  _lazyfleet_stack_branch $p || return 1; br=$REPLY
  _lazyfleet_diffbase $repo $br || return 1; base=$REPLY
  n=$(git -C $p rev-list --count $base..HEAD 2>/dev/null) || return 1
  (( n == 1 )) && n='1 commit' || n="$n commits"
  print -r -- $'\e[1m'"$n since $base"$'\e[0m  \e[2m(D: the diff in your pager)\e[0m'
  git -C $p log --oneline --color=always -n 15 $base..HEAD
  git -C $p --no-optional-locks diff --color=always --stat=72 --stat-count=12 $base...HEAD 2>/dev/null
  _lazyfleet_diff_head $p $base
  return 0
}

# Print the first _LAZYFLEET_DIFF_LINES lines of the diff of worktree $1's
# commits since $2, and say when there is more
typeset -g _LAZYFLEET_DIFF_LINES=400
_lazyfleet_diff_head() {
  local -a lines
  lines=("${(@f)$(git -C $1 --no-optional-locks diff --color=always $2...HEAD 2>/dev/null | head -n $(( _LAZYFLEET_DIFF_LINES + 1 )))}")
  [[ -n $lines[1] ]] || return 0
  print
  print -rl -- "${(@)lines[1,_LAZYFLEET_DIFF_LINES]}"
  (( $#lines > _LAZYFLEET_DIFF_LINES )) && print -r -- $'\e[2m… more: D shows all of it\e[0m'
  return 0
}

# lazyfleet diff [worktree]: what the worktree's branch changes, committed or
# not: against its parent when it is stacked, else the default branch
_lazyfleet_diff() {
  _lazyfleet_diff_target "$1" || return 1
  git -C $reply[1] --no-optional-locks diff --merge-base $reply[2]
}

# REPLY=$LESS (git's FRX when unset) without -F / --quit-if-one-screen, so
# that less waits for q even when what it shows fits one screen
_lazyfleet_less_waits() { REPLY=${${${LESS-FRX}//--quit-if-one-screen/}//F/} }

# D in the TUI: the same in git's pager (delta, say), on the terminal. A diff
# that fits one screen would make less quit at once (its -F, which git sets
# by default): it is left out here, and a pager that does not wait (cat) gets
# a key to press.
_lazyfleet_ui_diff() {
  local p base pager
  _lazyfleet_diff_target "$1" || { _lazyfleet_pause; return 1 }
  p=$reply[1] base=$reply[2]
  if [[ -z $(git -C $p --no-optional-locks diff --merge-base $base --stat 2>/dev/null) ]]; then
    print -r -- "No changes since $base."; _lazyfleet_pause; return 0
  fi
  pager=$(git -C $p var GIT_PAGER 2>/dev/null)
  _lazyfleet_less_waits
  LESS=$REPLY _lazyfleet_stack_onterm git -C $p --no-optional-locks --paginate diff --merge-base $base
  [[ $pager == (|cat) ]] && _lazyfleet_pause
  return 0
}

# --- the bases of pull requests --------------------------------------------------

# _lazyfleet_stack_misbased want... -- pr...
# want: "branch<TAB>parent", pr: "branch<TAB>number<TAB>base" (open pull
# requests). reply=("number<TAB>branch<TAB>base<TAB>parent" ...): each pull
# request of a stacked branch whose base is not the branch's parent.
_lazyfleet_stack_misbased() {
  local e b n base
  local -A want
  while (( $# )) && [[ $1 != -- ]]; do want[${1%%$'\t'*}]=${1#*$'\t'}; shift; done
  (( $# )) && shift
  reply=()
  for e in "$@"; do
    b=${e%%$'\t'*}; e=${e#*$'\t'}; n=${e%%$'\t'*}; base=${e#*$'\t'}
    [[ -n $want[$b] && $want[$b] != "$base" && $n == <1-> ]] &&
      reply+=("$n"$'\t'"$b"$'\t'"$base"$'\t'"$want[$b]")
  done
  return 0
}

# reply=("branch<TAB>number<TAB>base" ...): the open pull requests of GitHub
# repo $1 (owner/name) from its own branches, at most 100. What GitHub says is
# data: control characters go.
_lazyfleet_stack_prbases() {
  local out line
  local -a f
  out=$(gh api "repos/$1/pulls?state=open&per_page=100" \
    --jq '.[] | [.head.ref, (.head.repo.full_name // ""), (.number|tostring), .base.ref] | @tsv' 2>/dev/null) || return 1
  reply=()
  for line in ${(f)out}; do
    f=("${(@ps:\t:)line}")
    (( $#f == 4 )) && [[ ${f[2]:l} == ${1:l} ]] || continue
    reply+=("${f[1]//[[:cntrl:]]/}"$'\t'"${f[3]//[^0-9]/}"$'\t'"${f[4]//[[:cntrl:]]/}")
  done
  return 0
}

# _lazyfleet_stack_fixbases repo owner/name ask branch...
# Line the open pull requests of the branches up with their stack: list the
# ones whose base is not the branch's parent, then (ask non-empty) offer to
# change their base, or else say how. Never fails: the push is done.
_lazyfleet_stack_fixbases() {
  local repo=$1 slug=$2 ask=$3 b e t=$'\t'  # ($'\t' isn't expanded inside a subscript)
  local -a want entries bad f
  shift 3
  _lazyfleet_stack_load $repo; entries=($reply)
  for b in "$@"; do
    e=${entries[(r)${(b)b}$t*]}
    [[ -n $e ]] || continue
    e=${${e#*$t}%%$t*}
    # (a parent merged on GitHub: GitHub moved the pull request on, not lazyfleet)
    git -C $repo show-ref -q --verify refs/remotes/origin/$e && ! _lazyfleet_stack_merged $repo $e || continue
    want+=("$b$t$e")
  done
  (( $#want )) || return 0
  _lazyfleet_stack_prbases $slug || { print -ru2 -- "lazyfleet: could not check the bases of the pull requests (gh)"; return 0 }
  _lazyfleet_stack_misbased $want -- $reply; bad=($reply)
  (( $#bad )) || return 0
  print -ru2 -- "lazyfleet: these pull requests are not onto the branch below them in the stack:"
  for e in $bad; do f=("${(@ps:\t:)e}"); print -ru2 -- "   #$f[1] $f[2]: onto $f[3], should be onto $f[4]"; done
  if [[ -z $ask ]]; then
    for e in $bad; do f=("${(@ps:\t:)e}"); print -ru2 -- "   gh pr edit $f[1] --base $f[4]"; done
    return 0
  fi
  _lazyfleet_ask "Change their base?" || return 0
  for e in $bad; do
    f=("${(@ps:\t:)e}")
    _lazyfleet_step "Moving #$f[1] onto $f[4]"
    gh api -X PATCH "repos/$slug/pulls/$f[1]" -f base=$f[4] >/dev/null 2>&1
    _lazyfleet_done
  done
  return 0
}

# --- the stack command --------------------------------------------------------

# lazyfleet stack [show|on <parent>|off|restack] [worktree]
_lazyfleet_stack() {
  local sub=${1:-show}
  (( $# )) && shift
  case $sub in
    (show) _lazyfleet_stack_show "$@" ;;
    (on) _lazyfleet_stack_on "$@" ;;
    (off) _lazyfleet_stack_off "$@" ;;
    (restack)
      # on a terminal, a conflict is resolved file by file
      if [[ -t 0 && -t 1 ]]; then _lazyfleet_stack_restack -i "$@"; else _lazyfleet_stack_restack "$@"; fi ;;
    (*) _lazyfleet_err 'usage: lazyfleet stack [show | on <parent> | off | restack] [worktree]'; return 1 ;;
  esac
}

# lazyfleet stack on <parent> [worktree]
_lazyfleet_stack_on() {
  [[ -n $1 ]] || { _lazyfleet_err 'usage: lazyfleet stack on <parent> [worktree]'; return 1 }
  local par=$1 repo br
  _lazyfleet_stack_here "$2" || return 1
  repo=$reply[1] br=$reply[2]
  _lazyfleet_stack_link $repo $br $par || return 1
  print -r -- "$br is stacked on $par"
}

# lazyfleet stack off [worktree]
_lazyfleet_stack_off() {
  local repo br
  _lazyfleet_stack_here "$1" || return 1
  repo=$reply[1] br=$reply[2]
  _lazyfleet_stack_unlink $repo $br || return 1
  print -r -- "$br is no longer stacked"
}

# lazyfleet stack show [worktree]
_lazyfleet_stack_show() {
  local repo br
  _lazyfleet_stack_here "$1" || return 1
  repo=$reply[1] br=$reply[2]
  _lazyfleet_stack_print $repo $br ||
    print -r -- "$br is not part of a stack (lazyfleet stack on <parent>)"
}

# Print the stack of branch $2 of repo $1 with a heading; fails when the
# branch is not stacked
_lazyfleet_stack_print() {
  local repo=$1 br=$2 trunk head
  local -a entries
  _lazyfleet_stack_load $repo; entries=($reply)
  _lazyfleet_stack_trunk $repo; trunk=$REPLY
  head=$'\e[1mStack\e[0m'
  _lazyfleet_stack_pos $br "$trunk" $entries && head+="  $REPLY"
  _lazyfleet_stack_tree $br $entries || return 1
  [[ ${(F)reply} == *⟲* ]] && head+=$'  \e[2m(r or lazyfleet stack restack)\e[0m'
  print -r -- $head
  print -rl -- $reply
}

# The preview's stack section for worktree $1, when its branch is stacked
_lazyfleet_stack_preview() {
  local repo out
  _lazyfleet_toplevel $1 || return 0
  repo=$REPLY
  _lazyfleet_stack_branch $1 || return 0
  out=$(_lazyfleet_stack_print $repo $REPLY) || return 0
  print
  print -r -- $out
  _lazyfleet_stack_rebasing $1 || return 0
  _lazyfleet_stack_unmerged $1
  (( $#reply )) && print -r -- $'   \e[33m'"$#reply file(s) in conflict: r resolves them"$'\e[0m'
  return 0
}

# reply=("branch<TAB>mark" ...): the row mark of each stacked branch of repo
# $1; -p first for plain marks
_lazyfleet_stack_rowmarks() {
  local plain= repo trunk e b
  local -a entries out
  [[ $1 == -p ]] && { plain=-p; shift }
  repo=$1
  _lazyfleet_stack_load $repo; entries=($reply)
  (( $#entries )) || { reply=(); return 0 }
  _lazyfleet_stack_trunk $repo; trunk=$REPLY
  for e in $entries; do
    b=${e%%$'\t'*}
    _lazyfleet_stack_pos $b "$trunk" $entries || continue
    _lazyfleet_stack_mark $plain $REPLY ${e##*$'\t'}
    out+=("$b"$'\t'"$REPLY")
  done
  reply=($out)
}
