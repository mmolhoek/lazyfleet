#!/usr/bin/env -S zsh -f
# Tests for `lazyfleet prune`. A local bare repository stands in for GitHub
# (git is told it is acme/widgets), gh is a stub serving the pull request list.

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools git tmux
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg LAZYFLEET_WORKTREES=$SANDBOX/wt TMPDIR=$SANDBOX/tmp
export TMUX_TMPDIR=$SANDBOX GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LAZYFLEET_AGENT_DIR=$SANDBOX/agents
mkdir -p $HOME $TMPDIR $SANDBOX/stub $SANDBOX/fix
setopt extended_glob
unset TMUX LAZYFLEET_PR_STATUS
export LAZYFLEET_TMUX="tmux -L lazyfleet-prune-$$" SHELL=${commands[zsh]}
source $ROOT/lazyfleet.zsh
cleanup() { _lazyfleet_tmux kill-server 2>/dev/null; rm -rf $SANDBOX }
trap cleanup EXIT

plain() { sed 's/\x1b\[[0-9;]*m//g' }

# git is told that origin is on GitHub (nothing else about git changes)
git() { if [[ $* == *'remote get-url origin'* ]]; then print -r -- https://github.com/acme/widgets.git; else command git "$@"; fi }

cat >$SANDBOX/stub/gh <<'STUB'
#!/bin/sh
[ "$1" = api ] || exit 2
ep=$2; shift 2
jqx=.
while [ $# -gt 0 ]; do case $1 in --jq|-q) jqx=$2; shift 2 ;; *) shift ;; esac; done
echo "$ep" >>"$GH_LOG"
[ -n "$GH_FAIL" ] && { echo "gh: HTTP 401" >&2; exit 1; }
case $ep in
  repos/acme/widgets/pulls\?*) f=$FIX/pulls.json ;;
  *) f=/nonexistent ;;
esac
[ -r "$f" ] || { echo "gh: HTTP 404" >&2; exit 1; }
jq -r "$jqx" "$f"
STUB
chmod +x $SANDBOX/stub/gh
export FIX=$SANDBOX/fix GH_LOG=$SANDBOX/gh.log
path=($SANDBOX/stub $path); rehash

origin=$SANDBOX/origin.git repo=$SANDBOX/app seed=$SANDBOX/seed
T=$'\t'
wt() { print -r -- $LAZYFLEET_WORKTREES/app/$1 }
exists() { [[ -d $1 ]] }
has_branch() { git -C $repo show-ref -q --verify refs/heads/$1 }
mkwt() {  # name: a worktree with one commit of its own
  git -C $repo worktree add -q -b $1 $(wt $1) origin/main 2>/dev/null
  git -C $(wt $1) commit -q --allow-empty -m "work on $1"
}
push() { git -C $(wt $1) push -q -u origin $1 2>/dev/null }
# merged on "GitHub" with a merge commit, and the branch deleted there
merge_remote() {
  git -C $seed pull -q origin main 2>/dev/null
  git -C $seed fetch -q origin
  git -C $seed merge -q --no-ff -m "merge $1" origin/$1 2>/dev/null
  git -C $seed push -q origin main
  git -C $seed push -q origin --delete $1 2>/dev/null
}
delete_remote() { git -C $seed push -q origin --delete $1 2>/dev/null }
# one entry of the pull request list gh serves
pr() {  # number state merged-at-or-empty branch sha
  jq -n --argjson n $1 --arg st $2 --arg mg "$3" --arg ref "$4" --arg sha "$5" \
    '{number:$n, state:$st, draft:false, merged_at:(if $mg=="" then null else $mg end), title:"t",
      html_url:"https://github.com/acme/widgets/pull/\($n)", head:{ref:$ref, sha:$sha, repo:{full_name:"acme/widgets"}}}'
}
prs_json() { jq -s . >$FIX/pulls.json }
tip() { git -C $(wt $1) rev-parse HEAD }

world() {
  _lazyfleet_tmux kill-server 2>/dev/null
  rm -rf $origin $seed $repo $LAZYFLEET_WORKTREES $SANDBOX/cfg $TMPDIR $GH_LOG $FIX/pulls.json
  mkdir -p $TMPDIR
  git init -q --bare -b main $origin
  git clone -q $origin $seed 2>/dev/null
  git -C $seed commit -q --allow-empty -m init && git -C $seed push -q origin main
  git clone -q $origin $repo 2>/dev/null
  # a merge commit on GitHub, branch deleted afterwards
  mkwt gone-merged;    push gone-merged;    merge_remote gone-merged
  # deleted on GitHub without being merged
  mkwt gone-unmerged;  push gone-unmerged;  delete_remote gone-unmerged
  # never pushed
  mkwt fresh
  # pushed and still there
  mkwt active;         push active
  # merged, but with uncommitted changes
  mkwt dirty;          push dirty;          merge_remote dirty
  print x >$(wt dirty)/new-file
  # merged, but locked
  mkwt locked;         push locked;         merge_remote locked
  git -C $repo worktree lock $(wt locked)
  # merged, with an agent in its tmux session
  mkwt busy;           push busy;           merge_remote busy
  # a squash-merged pull request: the commits are not in main, GitHub says merged
  mkwt squashed
  # the same, with a commit after the merge
  mkwt after
  local old=$(tip after)
  git -C $(wt after) commit -q --allow-empty -m "after the merge"
  # the pull request of this branch is open
  mkwt openpr
  # a detached worktree
  git -C $repo worktree add -q --detach $(wt detached) origin/main 2>/dev/null
  {
    pr 11 closed 2026-01-01T00:00:00Z squashed $(tip squashed)
    pr 12 closed 2026-01-01T00:00:00Z after $old
    pr 13 open '' openpr $(tip openpr)
  } | prs_json
  _lazyfleet_add $repo >/dev/null
}
FAKE_BUSY=
_lazyfleet_agents() { reply=(); [[ -n $FAKE_BUSY ]] && reply=("$FAKE_BUSY${T}1${T}claude"); return 0 }

# prune from inside the repo (RUNDIR changes that); sets $out, $err and $rc
run() {
  ( cd ${RUNDIR:-$repo} && _lazyfleet_main prune "$@" >$SANDBOX/out 2>$SANDBOX/err </dev/null )
  rc=$?
  out=$(plain <$SANDBOX/out); err=$(plain <$SANDBOX/err)
}
cd $SANDBOX

# --- what counts as merged, one worktree at a time
world
typeset -A prs
slug=acme/widgets
merged() { _lazyfleet_merged $repo $(wt $1) $slug; mrc=$?; mwhy=$REPLY }
git -C $repo fetch -q --prune origin
_lazyfleet_pr_cachefile acme/widgets && _lazyfleet_pr_fetch acme/widgets $REPLY gone-merged squashed after openpr >/dev/null 2>&1
_lazyfleet_pr_read acme/widgets
merged gone-merged
check 'a merge commit with the remote branch gone is merged' eval 'test $mrc = 0 && gq "merged into origin/main, and its remote branch is gone" <<<$mwhy'
merged gone-unmerged
check 'a deleted remote branch alone is not merged' eval 'test $mrc = 2 && gq "has commits origin/main does not" <<<$mwhy'
merged fresh
check 'a branch that was never pushed is not merged' test $mrc = 1
merged active
check 'a pushed branch that is still there is not merged' test $mrc = 1
merged squashed
check 'a squash-merged pull request at its last commit is merged' eval 'test $mrc = 0 && gq "pull request #11 was merged" <<<$mwhy'
merged after
check 'commits after the merge are not thrown away' eval 'test $mrc = 2 && gq "pull request #12 was merged, but after is not at the commit it was merged at" <<<$mwhy'
merged openpr
check 'an open pull request is not merged' test $mrc = 1
merged detached
check 'a detached worktree is never merged' test $mrc = 1
prs=()
merged squashed
check 'without pull request data a squash merge is not seen' test $mrc = 1
prs[acme/widgets:squashed]="11${T}merged${T}-${T}u${T}t"
merged squashed
check 'a cache without the head commit cannot be trusted' eval 'test $mrc = 2'
prs[acme/widgets:squashed]="11${T}merged${T}-${T}u${T}t${T}"
merged squashed
check 'an empty head commit cannot be trusted either' eval 'test $mrc = 2'
slug=
merged squashed
check 'no GitHub repository, no pull request rule' test $mrc = 1
slug=acme/widgets

# --- dry run
world
run -n
check 'a dry run lists what it would remove' eval 'gq "prune  gone-merged  —  merged into origin/main" <<<$out'
check 'it lists the squash-merged one' eval 'gq "prune  squashed  —  pull request #11 was merged" <<<$out'
check 'it does not list a branch that is not merged' eval '! gq "fresh\|active\|openpr\|detached" <<<$out'
check 'it lists the unsafe ones as kept, with the reason' eval 'gq "keep   dirty  —  .*but it has uncommitted changes" <<<$out'
check 'a locked one is kept' eval 'gq "keep   locked  —  .*but it is locked" <<<$out'
check 'one with a commit after the merge is kept' eval 'gq "keep   after  —  pull request #12 was merged, but" <<<$out'
check 'an unmerged deleted branch is kept' eval 'gq "keep   gone-unmerged  —  its remote branch is gone, but it has commits" <<<$out'
check 'a dry run says so' eval 'gq "would be removed (dry run)" <<<$out'
check 'a dry run succeeds' test $rc = 0
check 'a dry run removes nothing' eval 'exists $(wt gone-merged) && exists $(wt squashed)'
check 'the main worktree is never listed' eval '! gq "  prune  main" <<<$out'

# the main worktree is never pruned, even on a branch that looks merged
world
git -C $repo checkout -q -b main-work origin/main
git -C $repo commit -q --allow-empty -m "work in the main worktree"
git -C $repo push -q -u origin main-work 2>/dev/null
git -C $seed fetch -q origin; git -C $seed merge -q --no-ff -m "merge main-work" origin/main-work 2>/dev/null; git -C $seed push -q origin main 2>/dev/null; delete_remote main-work
git -C $repo fetch -q --prune origin
_lazyfleet_merged $repo $repo
check 'the main worktree would count as merged on that branch' test $? = 0
run -n --no-fetch
check 'but the main worktree is not listed' eval '! gq "main-work" <<<$out'

# --- agents
world; FAKE_BUSY=app/busy
run -n
check 'merged but with an agent running: kept' eval 'gq "keep   busy  —  .*but agents are running in app/busy" <<<$out'
check 'an agent in another worktree changes nothing' eval 'gq "prune  gone-merged" <<<$out'
FAKE_BUSY=

# --- without a terminal, and with -y
world
run
check 'without a terminal and without -y it refuses' eval 'test $rc = 1 && gq "use -y" <<<$err'
check 'and removes nothing' eval 'exists $(wt gone-merged)'
run -y
check '-y removes them' test $rc = 0
check 'the merged worktree is gone' not exists $(wt gone-merged)
check 'the squash-merged worktree is gone' not exists $(wt squashed)
check 'the one without an agent is gone too' not exists $(wt busy)
check 'their branches are deleted' eval '! has_branch gone-merged && ! has_branch squashed && ! has_branch busy'
check 'the summary counts them' eval 'gq "Removed 3 worktree(s)\." <<<$out'
for w in gone-unmerged fresh active dirty locked after openpr detached; do
  check "$w is untouched" exists $(wt $w)
done
check 'the unmerged branch is kept' has_branch gone-unmerged
check 'the commits after the merge are kept' has_branch after
check 'the main worktree is still there' exists $repo
run -y
check 'a second run has nothing to do' eval 'test $rc = 0 && gq "Nothing to prune\." <<<$out'

# a removal that fails is counted, and fails the command
world
( _lazyfleet_rm() { [[ ${@[-1]:t} == squashed ]] && return 1; return 0 }
  _lazyfleet_main prune -y -r app >$SANDBOX/out 2>&1 ); rc=$?
out=$(plain <$SANDBOX/out)
check 'a failed removal is reported' eval 'gq "Removed 2 worktree(s), 1 failed\." <<<$out'
check 'and the exit status says so' test $rc = 1

# --- keeping the branches
world
run -y --keep-branches
check '--keep-branches removes the worktrees' not exists $(wt gone-merged)
check '--keep-branches keeps the branches' eval 'has_branch gone-merged && has_branch squashed'

# --- fetching
world
# a branch that is merged and deleted only after the last fetch
mkwt late; push late; git -C $repo fetch -q origin; merge_remote late
run -n --no-fetch
check '--no-fetch does not see a branch deleted since the last fetch' eval '! gq "prune  late" <<<$out'
rm -f $GH_LOG
run -n
check 'by default it fetches first' eval 'gq "prune  late" <<<$out'
check 'asking GitHub happens once' eval 'test "$(grep -c pulls $GH_LOG)" = 1'
world
rm -f $FIX/pulls.json
run -n
check 'without pull request data the git rule still works' eval 'gq "prune  gone-merged" <<<$out && ! gq "prune  squashed" <<<$out'
world; LAZYFLEET_PR_STATUS=off run -n
check 'pr_status=off: no questions to GitHub' eval 'test ! -e $GH_LOG && gq "prune  gone-merged" <<<$out && ! gq "prune  squashed" <<<$out'
unset LAZYFLEET_PR_STATUS
world; GH_FAIL=1 run -n
check 'a failing gh does not stop the git rule' eval 'test $rc = 0 && gq "prune  gone-merged" <<<$out'
unset GH_FAIL

# --- which repositories
world
mkdir -p $SANDBOX/other && git init -q -b main $SANDBOX/other && git -C $SANDBOX/other commit -q --allow-empty -m i && _lazyfleet_add $SANDBOX/other >/dev/null
RUNDIR=$SANDBOX run -n
check 'outside a repository it asks for -r' eval 'test $rc = 1 && gq "not in a repo; pass -r <repo> or --all" <<<$err'
( cd $SANDBOX/other && out=$(_lazyfleet_main prune -n --no-fetch 2>&1); [[ $out == *'Nothing to prune'* ]] ) && ok 'inside another repository only that one counts' || fail 'inside another repository only that one counts'
RUNDIR=$SANDBOX run -n -r app
check '-r picks a repository by name' eval 'gq "prune  gone-merged" <<<$out'
RUNDIR=$SANDBOX run -n -r nothere
check '-r with an unknown repository fails' eval 'test $rc = 1 && gq "unknown repo" <<<$err'
RUNDIR=$SANDBOX run -n --all
check '--all goes through every repository' eval 'gq "prune  gone-merged" <<<$out'
RUNDIR=$SANDBOX run -n --all -r app
check '--all with -r is refused' eval 'test $rc = 1 && gq "not both" <<<$err'
run -n stray
check 'stray arguments are refused' eval 'test $rc = 1 && gq "usage: lazyfleet prune" <<<$err'
run -n --bogus
check 'unknown options are refused' test $rc = 1

# --- asked on a terminal (a tmux pane is the terminal)
ask() {  # $1=pane name
  _lazyfleet_tmux kill-session -t "=$1" 2>/dev/null
  _lazyfleet_tmux new-session -d -s $1 -x 150 -y 30 -c $repo "zsh -fc 'source $ROOT/lazyfleet.zsh; _lazyfleet_agents() { reply=() }; git() { if [[ \$* == *\"remote get-url origin\"* ]]; then print -r -- https://github.com/acme/widgets.git; else command git \"\$@\"; fi }; _lazyfleet_main prune; echo rc=\$?; sleep 5'"
}
world
ask p1
check 'it asks before removing' waitpane p1 'Remove 3 worktree(s)? [y/N]'
_lazyfleet_tmux send-keys -t '=p1:' n
check 'no stops it' waitpane p1 'rc=1'
check 'and nothing is removed' exists $(wt gone-merged)
_lazyfleet_tmux kill-session -t '=p1'
ask p2
waitpane p2 'Remove 3 worktree(s)? [y/N]'
_lazyfleet_tmux send-keys -t '=p2:' y
check 'yes removes them' waitpane p2 'Removed 3 worktree(s).'
check 'they are gone' not exists $(wt gone-merged)

# --- the session we are in goes last
world
order() {
  ( TMUX=x
    _lazyfleet_tmux() { if [[ $1 == display-message ]]; then print -r -- app/gone-merged; else command ${=LAZYFLEET_TMUX} "$@"; fi }
    _lazyfleet_rm() { print -r -- "rm ${@[-1]:t}" >>$SANDBOX/order; return 0 }
    _lazyfleet_main prune -y -r app >/dev/null 2>&1 )
}
rm -f $SANDBOX/order; order
check 'the session we are in is removed last' eval 'test "$(tail -1 $SANDBOX/order)" = "rm gone-merged"'
check 'the others were all removed too' eval 'test "$(wc -l <$SANDBOX/order | tr -d " ")" = 3'

check 'the help lists prune' eval '_lazyfleet_help | gq "lazyfleet prune"'
check 'completion lists prune' gq "'prune:" $ROOT/_lazyfleet

finish
