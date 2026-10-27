#!/usr/bin/env -S zsh -f
# Unit tests for the small helpers that the commands share: worktree entries,
# branches, on/off settings, the worktree argument, and the y/N question.

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools git
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg TMPDIR=$SANDBOX/tmp
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p $HOME $TMPDIR $XDG_CONFIG_HOME/lazyfleet
unset TMUX LAZYFLEET_STATUS_BRANCH LAZYFLEET_AGENT_NOTIFY LAZYFLEET_TRUST_BRANCH_CONFIG
export LAZYFLEET_TMUX="tmux -L lazyfleet-helpers-$$"
trap 'rm -rf $SANDBOX' EXIT
source $ROOT/lazyfleet.zsh

T=$'\t'
cfg=$XDG_CONFIG_HOME/lazyfleet/config

# --- worktree entries: "path<TAB>branch<TAB>ismain"
e="/src/app${T}feat/x${T}0"
_lazyfleet_wt_path $e;   assert_eq 'the path of an entry' /src/app $REPLY
_lazyfleet_wt_branch $e; assert_eq 'the branch of an entry, slash and all' feat/x $REPLY
_lazyfleet_wt_ismain $e; assert_eq 'a linked worktree is not main' 0 $REPLY
e="/src/app${T}(detached)${T}1"
_lazyfleet_wt_branch $e; assert_eq 'a detached entry names (detached)' '(detached)' $REPLY
_lazyfleet_wt_ismain $e; assert_eq 'the main worktree says 1' 1 $REPLY
e="/src/my app${T}a b${T}0"
_lazyfleet_wt_path $e;   assert_eq 'a path with a space survives' '/src/my app' $REPLY
_lazyfleet_wt_branch $e; assert_eq 'so does a branch with one' 'a b' $REPLY

# --- a repo with a worktree on a branch and one detached
repo=$SANDBOX/src/app
git init -q -b main $repo && git -C $repo commit -q --allow-empty -m init
git -C $repo worktree add -q -b feat/x $SANDBOX/wt/app/feat-x
git -C $repo worktree add -q --detach $SANDBOX/wt/app/detached
fx=$SANDBOX/wt/app/feat-x det=$SANDBOX/wt/app/detached
mkdir -p $SANDBOX/plain

# --- the branch of a worktree
_lazyfleet_branch_of $fx;   assert_eq 'branch_of gives the branch' feat/x $REPLY
_lazyfleet_branch_of $fx;   assert_eq 'and succeeds' 0 $?
_lazyfleet_branch_of $det;  assert_eq 'a detached HEAD fails' 1 $?
assert_eq 'and leaves REPLY empty' '' $REPLY
_lazyfleet_branch_of $SANDBOX/plain 2>/dev/null; assert_eq 'a directory that is no repo fails' 1 $?
out=$(_lazyfleet_need_branch $det 2>&1); rc=$?
assert_eq 'need_branch fails on a detached HEAD' 1 $rc
assert_contains 'and says why, with ~ for the home directory' 'lazyfleet: ~/wt/app/detached is not on a branch' "$(HOME=$SANDBOX _lazyfleet_need_branch $det 2>&1)"
assert_contains 'the message names the problem' 'is not on a branch' $out
_lazyfleet_need_branch $fx; assert_eq 'need_branch gives the branch' feat/x $REPLY

# --- on/off settings
rm -f $cfg
_lazyfleet_flag s_one LF_NOPE on;  assert_eq 'a setting is on by default when the default says on' 0 $?
_lazyfleet_flag s_one LF_NOPE off; assert_eq 'off by default when the default says off' 1 $?
for v in off OFF Off no No false FALSE 0; do
  print -r -- "s_one=$v" >$cfg
  _lazyfleet_flag s_one LF_NOPE on; assert_eq "$v in the config file turns it off" 1 $?
done
for v in on yes true 1 whatever; do
  print -r -- "s_one=$v" >$cfg
  _lazyfleet_flag s_one LF_NOPE on; assert_eq "$v in the config file leaves it on" 0 $?
done
print -r -- 's_one=on' >$cfg
LF_ENV=off _lazyfleet_flag s_one LF_ENV on; assert_eq 'the env var wins over the config file' 1 $?
print -r -- 's_one=off' >$cfg
LF_ENV=on _lazyfleet_flag s_one LF_ENV on;  assert_eq 'and the other way round' 0 $?
print -l '[app]' 's_one=off' >$cfg
_lazyfleet_flag s_one LF_NOPE on; assert_eq 'a [section] does not set a global setting' 0 $?
print -r -- 's_one=off' >$cfg; _lazyfleet_flag s_one LF_NOPE on
assert_eq 'the value is left in REPLY' off $REPLY
rm -f $cfg
# the status bar branch used to ignore the case of OFF
LAZYFLEET_STATUS_BRANCH=OFF _lazyfleet_flag status_branch LAZYFLEET_STATUS_BRANCH on
assert_eq 'status_branch=OFF is off, in any case' 1 $?

# --- the worktree argument of rm and pull
_lazyfleet_add $repo >/dev/null
_lazyfleet_worktree_arg $fx 'usage: x';        assert_eq 'a path names its worktree' $fx $REPLY
_lazyfleet_worktree_arg feat/x 'usage: x';     assert_eq 'a branch names its worktree' $fx $REPLY
_lazyfleet_worktree_arg app/feat-x 'usage: x'; assert_eq 'a session name names its worktree' $fx $REPLY
(cd $fx && _lazyfleet_worktree_arg '' 'usage: x'; print -r -- $REPLY) >$SANDBOX/out
assert_eq 'no argument means the worktree we are in' $fx "$(<$SANDBOX/out)"
out=$(cd $SANDBOX/plain && _lazyfleet_worktree_arg '' 'usage: lazyfleet rm <worktree>' 2>&1); rc=$?
assert_eq 'no argument outside a worktree fails' 1 $rc
assert_contains 'with the usage message' 'lazyfleet: usage: lazyfleet rm <worktree>' $out
out=$(_lazyfleet_worktree_arg nosuch 'usage: x' 2>&1); rc=$?
assert_eq 'an unknown name fails' 1 $rc
assert_contains 'and says how many matched' "no unique worktree for 'nosuch' (0 matches)" $out
git -C $repo worktree add -q -b other/feat-x $SANDBOX/wt/app/other-feat-x
git -C $repo worktree add -q -b feat-x $SANDBOX/wt/app/feat-x2 2>/dev/null
out=$(_lazyfleet_worktree_arg feat-x 'usage: x' 2>&1); rc=$?
assert_eq 'a name two worktrees answer to fails' 1 $rc
assert_contains 'and counts them' "no unique worktree for 'feat-x' (2 matches)" $out

# --- a line of the prune report
entry="/wt/app/feat-x${T}feat/x${T}pull request #4 was merged"
assert_eq 'a prune line names the branch and the reason' '  prune  feat/x  —  pull request #4 was merged' "$(_lazyfleet_prune_line prune $entry)"
assert_eq 'a keep line lines up with it' '  keep   feat/x  —  pull request #4 was merged' "$(_lazyfleet_prune_line keep $entry)"
entry="/wt${T}evil"$'\e[31m'"x${T}gone"$'\a'"y"
assert_eq 'control characters are made spaces, not passed to the terminal' '  prune  evil [31mx  —  gone y' "$(_lazyfleet_prune_line prune $entry)"

# --- the question. The keyboard is replaced: it types what $typed holds.
# (The real read -q is exercised by the TUI suite, in a real tmux pane.)
_lazyfleet_readkey() { [[ $typed == [yY] ]] }
ask() { typed=$1; _lazyfleet_ask 'Go on?' >$SANDBOX/ask.out; }
ask y; assert_eq 'y says yes' 0 $?
ask n; assert_eq 'n says no' 1 $?
ask x; assert_eq 'anything else says no' 1 $?
ask y
assert_eq 'the question ends in [y/N] and a space' 'Go on? [y/N] ' "$(<$SANDBOX/ask.out)"
assert_eq 'and the answer is followed by a newline' 1 "$(wc -l <$SANDBOX/ask.out | tr -d ' ')"
ask n
assert_eq 'a no is followed by a newline too' 1 "$(wc -l <$SANDBOX/ask.out | tr -d ' ')"

typed=y; _lazyfleet_confirm 'Go on?' >/dev/null </dev/null
assert_eq 'confirm without a message asks, even off a terminal' 0 $?
typed=n; _lazyfleet_confirm 'Go on?' >/dev/null </dev/null
assert_eq 'and passes a no on' 1 $?
typed=y; out=$(_lazyfleet_confirm 'Go on?' 'not on a terminal: use -y' </dev/null 2>&1); rc=$?
assert_eq 'confirm with a message fails off a terminal, whatever the answer' 1 $rc
assert_eq 'and only prints the message, it does not ask' 'lazyfleet: not on a terminal: use -y' "$out"

finish
