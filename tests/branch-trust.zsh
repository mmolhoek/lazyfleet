#!/usr/bin/env -S zsh -f
# Tests for which .lazyfleet a new worktree may take its setup= and copy= from:
# the worktree's own one comes from a branch that may not be yours.

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools git tmux
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg LAZYFLEET_WORKTREES=$SANDBOX/wt TMPDIR=$SANDBOX/tmp
export TMUX_TMPDIR=$SANDBOX GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p $HOME $TMPDIR $XDG_CONFIG_HOME/lazyfleet
unset TMUX LAZYFLEET_TRUST_BRANCH_CONFIG
export LAZYFLEET_TMUX="tmux -L lazyfleet-trust-$$" SHELL=${commands[zsh]}
print -r -- '' >$HOME/.zshrc
source $ROOT/lazyfleet.zsh
cleanup() { _lazyfleet_tmux kill-server 2>/dev/null; rm -rf $SANDBOX }
trap cleanup EXIT


# a repo "app" whose main worktree says setup=trusted and copy=a.env; a branch
# "evil" whose own .lazyfleet says something else
repo=$SANDBOX/app
git init -q -b main $repo
print -l 'setup=echo trusted' 'copy=a.env' >$repo/.lazyfleet
print secret >$repo/a.env
print outside >$SANDBOX/outside.txt
git -C $repo add -A -f && git -C $repo commit -q -m init
git -C $repo branch same
git -C $repo checkout -q -b evil
print -l 'setup=touch PWNED' 'copy=a.env ../outside.txt /etc/hostname' >$repo/.lazyfleet
git -C $repo commit -q -am evil
git -C $repo checkout -q main
git -C $repo worktree add -q $LAZYFLEET_WORKTREES/app/evil evil
git -C $repo worktree add -q $LAZYFLEET_WORKTREES/app/same same
ev=$LAZYFLEET_WORKTREES/app/evil sm=$LAZYFLEET_WORKTREES/app/same

# --- _lazyfleet_conf
check 'a branch whose value differs gets the main worktree'"'"'s' eval '_lazyfleet_conf setup $ev $repo && [[ $REPLY == "echo trusted" && $_lazyfleet_ignored == setup ]]'
check 'the value that was passed over is reported for the key' eval '_lazyfleet_conf copy $ev $repo && [[ $REPLY == a.env && $_lazyfleet_ignored == copy ]]'
check 'a branch with the same value is used, nothing is reported' eval '_lazyfleet_conf setup $sm $repo && [[ $REPLY == "echo trusted" && -z $_lazyfleet_ignored && $_lazyfleet_from == .lazyfleet ]]'
check 'the main worktree itself is trusted' eval '_lazyfleet_conf setup $repo $repo && [[ $REPLY == "echo trusted" && -z $_lazyfleet_ignored ]]'
check 'a branch key the main worktree lacks is not trusted' eval 'print other=x >>$ev/.lazyfleet; ! _lazyfleet_conf other $ev $repo && [[ $_lazyfleet_ignored == other ]]'
print -l 'setup=from-project' >$XDG_CONFIG_HOME/lazyfleet/projects.tmp; mkdir -p $XDG_CONFIG_HOME/lazyfleet/projects
mv $XDG_CONFIG_HOME/lazyfleet/projects.tmp $XDG_CONFIG_HOME/lazyfleet/projects/app.conf
check 'your own project file still wins, and reports nothing' eval '_lazyfleet_conf setup $ev $repo && [[ $REPLY == from-project && -z $_lazyfleet_ignored ]]'
rm -f $XDG_CONFIG_HOME/lazyfleet/projects/app.conf
check 'trust_branch_config=on in the config file trusts the branch' eval 'print trust_branch_config=on >$XDG_CONFIG_HOME/lazyfleet/config; _lazyfleet_conf setup $ev $repo && [[ $REPLY == "touch PWNED" && -z $_lazyfleet_ignored ]]'
rm -f $XDG_CONFIG_HOME/lazyfleet/config
check 'LAZYFLEET_TRUST_BRANCH_CONFIG=on trusts the branch' eval 'LAZYFLEET_TRUST_BRANCH_CONFIG=on _lazyfleet_conf setup $ev $repo && [[ $REPLY == "touch PWNED" ]]'
check 'a [section] in the config file cannot switch trust on' eval 'print -l "[app]" trust_branch_config=on >$XDG_CONFIG_HOME/lazyfleet/config; _lazyfleet_conf setup $ev $repo && [[ $REPLY == "echo trusted" ]]'
rm -f $XDG_CONFIG_HOME/lazyfleet/config

# --- _lazyfleet_inside
check 'a plain relative path is inside' _lazyfleet_inside .env.local
check 'a nested path is inside' _lazyfleet_inside config/.env
check 'a name that merely contains dots is inside' _lazyfleet_inside ..env
check 'an absolute path is not inside' eval '! _lazyfleet_inside /etc/hostname'
check 'a leading .. is not inside' eval '! _lazyfleet_inside ../outside.txt'
check 'a .. in the middle is not inside' eval '! _lazyfleet_inside a/../../b'
check 'a trailing .. is not inside' eval '! _lazyfleet_inside a/..'
check 'a bare .. is not inside' eval '! _lazyfleet_inside ..'

# --- new, end to end: an existing branch with its own .lazyfleet
git -C $repo worktree remove --force $ev
out=$(_lazyfleet_new evil --no-open -r $repo 2>&1 >/dev/null)
ev=$LAZYFLEET_WORKTREES/app/evil
check 'new says it skipped the branch'"'"'s setup' eval 'gq -F "setup   skipped the branch'"'"'s .lazyfleet value" <<<$out'
check 'new runs the main worktree'"'"'s setup instead' eval 'gq -F "setup   echo trusted" <<<$out'
check 'the branch'"'"'s setup did not run' eval 'sleep 1; [[ ! -e $ev/PWNED ]]'
check 'new copies from the main worktree'"'"'s list' test -f $ev/a.env
# the path check also holds for a list you wrote yourself
mkdir -p $XDG_CONFIG_HOME/lazyfleet/projects
print -l 'copy=a.env ../outside.txt /etc/hostname' >$XDG_CONFIG_HOME/lazyfleet/projects/app.conf
out=$(_lazyfleet_new feat/paths --no-open -r $repo 2>&1 >/dev/null)
fp=$LAZYFLEET_WORKTREES/app/feat-paths
check 'a copy inside the repo still works' test -f $fp/a.env
check 'a copy from outside the repo is refused and said so' eval 'gq -F "skipped ../outside.txt: not a path inside the repo" <<<$out && gq -F "skipped /etc/hostname: not a path inside the repo" <<<$out'
check 'nothing was written outside the worktree' eval '[[ ! -e $LAZYFLEET_WORKTREES/app/outside.txt && ! -e $fp/hostname && ! -e $fp/outside.txt ]]'
_lazyfleet_tmux kill-server 2>/dev/null

finish
