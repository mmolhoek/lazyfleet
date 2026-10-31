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

# _lazyfleet_stack_restack_one repo branch parent rev
# Rebase the branch, in its own worktree, onto its parent: the commits after
# rev (the parent's commit it was last based on) go on top of the parent's
# tip. A parent that is gone is replaced by the default branch, for good. A
# branch already on its parent's tip only has rev brought up to date.
_lazyfleet_stack_restack_one() {
  local repo=$1 br=$2 par=$3 rev=$4 wt out
  if ! _lazyfleet_stack_isbranch $repo $par; then
    _lazyfleet_stack_trunk $repo ||
      { _lazyfleet_err "$br: its parent $par is gone, and there is no main or master to move it onto"; return 1 }
    print -ru2 -- "lazyfleet: $br: its parent $par is gone, so it moves onto $REPLY"
    par=$REPLY
  fi
  if git -C $repo merge-base --is-ancestor refs/heads/$par refs/heads/$br; then
    _lazyfleet_stack_link $repo $br $par $(git -C $repo rev-parse refs/heads/$par)
    return
  fi
  _lazyfleet_stack_wt $repo $br || return 1
  wt=$REPLY
  [[ -z $(git -C $wt status --porcelain --untracked-files=no 2>/dev/null) ]] ||
    { _lazyfleet_err "$br has uncommitted changes in ${wt/#$HOME/~}: commit or stash them first"; return 1 }
  _lazyfleet_stack_upstream $repo $br $par "$rev"; rev=$REPLY
  _lazyfleet_step "Restacking $br onto $par"
  out=$(git -C $wt rebase -q --onto refs/heads/$par $rev 2>&1)
  _lazyfleet_done || { _lazyfleet_stack_stopped $br $wt "$out"; return 1 }
  _lazyfleet_stack_link $repo $br $par $(git -C $repo rev-parse refs/heads/$par)
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

# Say how to go on after the rebase of branch $1 in worktree $2 stopped,
# with git's output $3
_lazyfleet_stack_stopped() {
  [[ -n $3 ]] && print -ru2 -- $3
  if [[ -n $(git -C $2 rev-parse -q --verify REBASE_HEAD 2>/dev/null) ]]; then
    print -ru2 -- "lazyfleet: the rebase of $1 stopped on a conflict in ${2/#$HOME/~}."
    print -ru2 -- "  Resolve it there and run git rebase --continue (or --abort), then restack again."
  fi
}

# reply=(repo, branch) of worktree $1 (default: the one we are in)
_lazyfleet_stack_here() {
  local p repo
  _lazyfleet_worktree_arg "$1" 'not in a worktree; name one' || return 1
  p=$REPLY
  _lazyfleet_toplevel $p || { _lazyfleet_err "not a git worktree: $p"; return 1 }
  repo=$REPLY
  _lazyfleet_need_branch $p || return 1
  reply=($repo $REPLY)
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

# lazyfleet stack restack [worktree]: rebase each branch of the worktree's
# stack onto its parent, bottom up; stops at the first one that fails
_lazyfleet_stack_restack() {
  local repo br b e t=$'\t'  # ($'\t' isn't expanded inside a subscript)
  local -a entries f
  _lazyfleet_stack_here "$1" || return 1
  repo=$reply[1] br=$reply[2]
  _lazyfleet_stack_load $repo; entries=($reply)
  _lazyfleet_stack_order $br $entries ||
    { _lazyfleet_err "$br is not part of a stack (lazyfleet stack on <parent>)"; return 1 }
  for b in $reply; do
    e=${entries[(r)${(b)b}$t*]}
    f=("${(@ps:\t:)e}")
    _lazyfleet_stack_restack_one $repo $b $f[2] "$f[3]" || return 1
  done
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
    (restack) _lazyfleet_stack_restack "$@" ;;
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
  [[ ${(F)reply} == *⟲* ]] && head+=$'  \e[2m(S or lazyfleet stack restack)\e[0m'
  print -r -- $head
  print -rl -- $reply
}

# The preview's stack section for worktree $1, when its branch is stacked
_lazyfleet_stack_preview() {
  local repo out
  _lazyfleet_toplevel $1 || return 0
  repo=$REPLY
  _lazyfleet_branch_of $1 || return 0
  out=$(_lazyfleet_stack_print $repo $REPLY) || return 0
  print
  print -r -- $out
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
