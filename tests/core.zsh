#!/usr/bin/env -S zsh -f
# Unit tests for the plumbing in lib/core.zsh that reads git's own files:
# worktree entries straight from .git (no fork), HEAD files, the main worktree
# of a path, and tmux session names.

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools git
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg TMPDIR=$SANDBOX/tmp
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p $HOME $TMPDIR
unset TMUX
trap 'rm -rf $SANDBOX' EXIT
source $ROOT/lazyfleet.zsh

T=$'\t'

# relpath <to> <from>: the path to <to> relative to directory <from>, both
# absolute (macOS realpath has no --relative-to)
relpath() {
  local -a to=(${(s:/:)${1:A}}) from=(${(s:/:)${2:A}})
  local i=1 up=
  while (( i <= $#to && i <= $#from )) && [[ $to[i] == $from[i] ]]; do (( i++ )); done
  repeat $(( $#from - i + 1 )) up+=../
  print -r -- ${up}${(j:/:)to[i,-1]}
}

# --- HEAD files
print -r -- 'ref: refs/heads/feat/x' >$SANDBOX/HEAD
_lazyfleet_head $SANDBOX/HEAD; assert_eq 'head: a branch, slash and all' feat/x $REPLY
print -r -- 0123456789abcdef0123456789abcdef01234567 >$SANDBOX/HEAD
_lazyfleet_head $SANDBOX/HEAD; assert_eq 'head: a commit is detached' '(detached)' $REPLY
print -r -- 'ref: refs/remotes/origin/main' >$SANDBOX/HEAD
_lazyfleet_head $SANDBOX/HEAD; assert_eq 'head: a ref outside heads is detached' '(detached)' $REPLY

# --- a repo with worktrees, read straight from .git
repo=$SANDBOX/src/app
git init -q -b main $repo && git -C $repo commit -q --allow-empty -m init
git -C $repo worktree add -q -b feat/x $SANDBOX/wt/feat-x
git -C $repo worktree add -q --detach $SANDBOX/wt/det
git -C $repo worktree add -q -b gone $SANDBOX/wt/gone
rm -rf $SANDBOX/wt/gone

# the worktree entries git itself reports, as "path<TAB>branch<TAB>ismain"
from_git() {
  local line wt br m i=0
  for line in ${(f)"$(git -C $repo worktree list --porcelain)"} 'worktree '; do
    case $line in
      ('worktree '*) [[ -n $wt && -d $wt ]] && print -r -- "$wt$T$br$T$m"
        wt=${line#worktree }; br='(detached)'; m=$(( i++ == 0 )) ;;
      ('branch '*) br=${line#branch refs/heads/} ;;
    esac
  done | sort
}
expected=$(from_git)
_lazyfleet_worktrees_raw $repo
assert_eq 'worktrees: the same as git says, absolute paths' "$expected" "$(print -rl -- $reply | sort)"
assert_contains 'worktrees: the main one is marked' "$repo${T}main${T}1" "$(print -rl -- $reply)"
check 'worktrees: a deleted worktree is left out' eval '[[ ${(F)reply} != *wt/gone* ]]'

# git 2.48+ can store relative links (worktree.useRelativePaths): gitdir is
# then relative to its own directory, .git/worktrees/<id>. Write them by hand,
# so this runs with any git.
for d in $repo/.git/worktrees/*(/); do
  wt=$(<$d/gitdir)
  [[ -d ${wt:h} ]] || continue
  relpath $wt $d >$d/gitdir
done
check 'relative: the fixture really is relative now' eval '[[ $(<$repo/.git/worktrees/feat-x/gitdir) == ../* ]]'
_lazyfleet_worktrees_raw $repo
assert_eq 'relative: the same worktrees as with absolute paths' "$expected" "$(print -rl -- $reply | sort)"
check 'relative: never git'"'"'s own metadata dir' eval '[[ ${(F)reply} != */.git/worktrees/* ]]'

# and the real thing, when this git can make it (2.48+)
if git -C $repo worktree add -h 2>&1 | gq -- --relative-paths; then
  git -C $repo worktree add -q --relative-paths -b rel $SANDBOX/wt/rel
  check 'git relative: git really wrote a relative link' eval '[[ $(<$repo/.git/worktrees/rel/gitdir) != /* ]]'
  _lazyfleet_worktrees_raw $repo
  assert_contains 'git relative: the worktree is where git put it' "$SANDBOX/wt/rel${T}rel${T}0" "$(print -rl -- $reply)"
  _lazyfleet_toplevel $SANDBOX/wt/rel; assert_eq 'git relative: and leads back to its repo' $repo $REPLY
else
  skip 'worktrees git links with relative paths' "git $(git --version | cut -d' ' -f3) is older than 2.48"
fi

# --- the main worktree of a path
_lazyfleet_toplevel $repo;            assert_eq 'toplevel: the main worktree is itself' $repo $REPLY
_lazyfleet_toplevel $SANDBOX/wt/feat-x; assert_eq 'toplevel: a linked worktree leads to the main one' $repo $REPLY
mkdir -p $SANDBOX/wt/feat-x/sub/dir
_lazyfleet_toplevel $SANDBOX/wt/feat-x/sub/dir; assert_eq 'toplevel: from deep inside a linked worktree' $repo $REPLY
# a linked worktree's .git file may hold a relative link too
print -r -- "gitdir: $(relpath $repo/.git/worktrees/det $SANDBOX/wt/det)" >$SANDBOX/wt/det/.git
_lazyfleet_toplevel $SANDBOX/wt/det; assert_eq 'toplevel: a relative .git file' $repo $REPLY
mkdir -p $SANDBOX/plain
check 'toplevel: no repo fails' not _lazyfleet_toplevel $SANDBOX/plain

assert_eq 'relpath: helper sanity' ../../b/c "$(relpath /x/b/c /x/y/z)"

# --- tmux session names: tmux takes neither . nor : in one
typeset -a cases=(
  # repo                 worktree                  main  expected
  /src/app               /src/app                  1     app
  /src/app               /wt/app/feat-x            0     app/feat-x
  /src/my.app            /src/my.app               1     my-app
  /src/app               /wt/app/v1.2:hotfix       0     app/v1-2-hotfix
  /src/app               /wt/app/feat-x            ''    app/feat-x
)
for repo_p wt_p main want in "${(@)cases}"; do
  _lazyfleet_session $repo_p $wt_p $main
  assert_eq "session: ${repo_p:t} ${wt_p:t} (main=${main:-unset})" $want $REPLY
done

finish
