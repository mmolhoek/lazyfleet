#!/usr/bin/env -S zsh -f
# Tests for removing a worktree that has submodules checked out: git refuses
# that unless forced, and forcing deletes the worktree's own copy of each
# submodule's repository, so commits that are on no remote are asked about
# first (lazyfleet rm, lib/commands.zsh).

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools git
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg LAZYFLEET_WORKTREES=$SANDBOX/wt TMPDIR=$SANDBOX/tmp
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# submodules from local paths need this since git 2.38.1
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
mkdir -p $HOME $TMPDIR
unset TMUX
export LAZYFLEET_UPDATE_CHECK=off LAZYFLEET_TMUX=false
trap 'rm -rf $SANDBOX' EXIT
source $ROOT/lazyfleet.zsh
_lazyfleet_session_agents() { reply=() }

# "deep" inside "lib" inside "app": each one a submodule of the next
for r in deep lib; do git init -q -b main $SANDBOX/$r && git -C $SANDBOX/$r commit -q --allow-empty -m $r; done
git -C $SANDBOX/lib submodule add -q $SANDBOX/deep deep && git -C $SANDBOX/lib commit -q -m 'add deep'
repo=$SANDBOX/app
git init -q -b main $repo && git -C $repo submodule add -q $SANDBOX/lib lib && git -C $repo commit -q -m 'add lib'

# mkwt <name> [init]: a worktree of app; with init, its submodules checked out
mkwt() {
  local w=$LAZYFLEET_WORKTREES/app/$1
  git -C $repo worktree add -q -b $1 $w 2>/dev/null
  [[ -n $2 ]] && git -C $w submodule update -q --init --recursive 2>/dev/null
  REPLY=$w
}
gone() { [[ ! -e $1 ]] && ! git -C $repo worktree list --porcelain | grep -qx "worktree $1" }
# a commit in submodule $2 of worktree $1 that no remote has, on a branch of
# its own: the submodule stays at the commit app records, so app sees no change
local_commit() {
  git -C $1/$2 checkout -q -b wip-$RANDOM && git -C $1/$2 commit -q --allow-empty -m "only here $(( ++nlocal ))" &&
    git -C $1/$2 checkout -q --detach HEAD~1
}
typeset -i nlocal=0
rm_() { out=$(_lazyfleet_rm "$@" </dev/null 2>&1); rc=$? }

# --- which submodules a worktree has checked out
mkwt plain; w=$REPLY
_lazyfleet_submodules $w
assert_eq 'submodules: none checked out, none' 0 $#reply
mkwt full init; w=$REPLY
_lazyfleet_submodules $w
assert_eq 'submodules: the checked-out ones, nested too, as paths in the worktree' 'lib lib/deep' "${(j: :)reply}"
mkdir -p $SANDBOX/none && git -C $SANDBOX/none init -q
_lazyfleet_submodules $SANDBOX/none
assert_eq 'submodules: a repo without .gitmodules, none' 0 $#reply

# --- commits that are on no remote
_lazyfleet_submodules_unpushed $w lib lib/deep
assert_eq 'unpushed: as checked out, none' 0 $#reply
local_commit $w lib
_lazyfleet_submodules_unpushed $w lib lib/deep
assert_eq 'unpushed: a commit made there' 'lib: 1 commit' "$reply"
local_commit $w lib/deep; local_commit $w lib/deep
_lazyfleet_submodules_unpushed $w lib lib/deep
assert_eq 'unpushed: in a nested one too, counted' 'lib: 1 commit|lib/deep: 2 commits' "${(j:|:)reply}"
check 'unpushed: app sees no change in them' test -z "$(git -C $w status --porcelain --ignore-submodules=none)"
git -C $w/lib/deep checkout -q ${$(git -C $w/lib/deep for-each-ref --count=1 --format='%(refname:short)' 'refs/heads/wip-*')}
_lazyfleet_submodules_unpushed $w lib/deep
assert_eq 'unpushed: on the checked-out commit too' 'lib/deep: 2 commits' "$reply"
git -C $w submodule update -q --recursive     # (back to what app records)
_lazyfleet_submodules_unpushed $w nothing-here
assert_eq 'unpushed: a path that is no repo, nothing' 0 $#reply

# --- removing: the crash this is about
mkwt clean init; w=$REPLY
check 'git itself refuses it' eval '! git -C $repo worktree remove $w 2>/dev/null'
rm_ $w
assert_eq 'rm: a worktree with submodules is removed' 0 $rc
check 'rm: all of it, with its submodule repositories' gone $w
check 'rm: and git'"'"'s admin dir for it' test ! -e $repo/.git/worktrees/clean
check 'rm: without a word about submodules' eval '[[ $out != *submodule* ]]'

mkwt uninit; w=$REPLY
rm_ $w
check 'rm: submodules not checked out need nothing' eval '(( rc == 0 )) && gone $w'

rm_ $SANDBOX/wt/app/plain
check 'rm: no submodules at all, as before' eval '(( rc == 0 )) && gone $SANDBOX/wt/app/plain'

# --- commits that would be lost
w=$SANDBOX/wt/app/full
rm_ $w
assert_eq 'rm: unpushed submodule commits, off a terminal: refused' 1 $rc
assert_contains 'rm: says which and how to override' "has submodule commits that are on no remote: lib: 1 commit, lib/deep: 2 commits (use -f)" $out
check 'rm: the worktree is still there' test -d $w/lib/deep
rm_ -f $w
check 'rm: -f removes it anyway' eval '(( rc == 0 )) && gone $w'

# with a terminal: asked
mkwt asked init; w=$REPLY; local_commit $w lib
(
  _lazyfleet_confirm() { _lazyfleet_ask $1 }
  _lazyfleet_ask() { print -r -- "asked: $1"; [[ $typed == y ]] }
  typed=n; rm_ $w
  assert_eq 'ask: no keeps it' 1 $rc
  assert_contains 'ask: names them, and what removing does' "has submodule commits that are on no remote (lib: 1 commit); removing the worktree deletes them. Remove anyway?" $out
  check 'ask: no, still there' test -d $w/lib
  typed=y; rm_ $w
  check 'ask: yes removes it' eval '(( rc == 0 )) && gone $w'
  # a commit on what the submodule has checked out: app sees that as a change
  mkwt asked2 init; w=$REPLY
  git -C $w/lib commit -q --allow-empty -m 'on HEAD'
  typed=y; rm_ $w
  check 'ask: then both are asked' eval '[[ $out == *"uncommitted changes"*"submodule commits that are on no remote (lib: 1 commit)"* ]]'
  check 'ask: and yes to both removes it' eval '(( rc == 0 )) && gone $w'
)

# --- changes inside a submodule are changes
mkwt dirty init; w=$REPLY
git -C $w config diff.ignoreSubmodules all     # (even when git is set to hide them)
print x >$w/lib/new.txt
rm_ $w
assert_eq 'changes: a new file in a submodule, refused' 1 $rc
assert_contains 'changes: as changes' "has changes (use -f)" $out
rm $w/lib/new.txt; print x >$w/lib/deep/new.txt
rm_ $w
assert_eq 'changes: in a nested one too' 1 $rc
rm_ -f $w
check 'changes: -f removes it' eval '(( rc == 0 )) && gone $w'

# --- the flags for git
mkwt flags init; w=$REPLY
_lazyfleet_rm_confirm $w $repo </dev/null >/dev/null 2>&1
assert_eq 'flags: git gets --force for submodules' --force "$REPLY"
git -C $repo worktree lock $w
_lazyfleet_rm_confirm $w $repo -f </dev/null >/dev/null 2>&1
assert_eq 'flags: and twice when locked too' '--force --force' "$REPLY"
git -C $repo worktree unlock $w
mkwt flags2; w=$REPLY
_lazyfleet_rm_confirm $w $repo </dev/null >/dev/null 2>&1
assert_eq 'flags: none when none are checked out' '' "$REPLY"

finish
