#!/usr/bin/env -S zsh -f
# Tests for `lazyfleet new --pr N` and `new --issue N`. No network: gh is a stub
# serving fixture JSON through the real jq; the "GitHub" remote is a local
# repository that git is told to call acme/widgets.

ROOT=${0:A:h:h}
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg LAZYFLEET_WORKTREES=$SANDBOX/wt TMPDIR=$SANDBOX/tmp
export TMUX_TMPDIR=$SANDBOX GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p $HOME $TMPDIR $SANDBOX/stub $SANDBOX/fix
setopt extended_glob
unset TMUX
export LAZYFLEET_TMUX="tmux -L lazyfleet-newpr-$$" SHELL=${commands[zsh]}
source $ROOT/lazyfleet.zsh
cleanup() { _lazyfleet_tmux kill-server 2>/dev/null; rm -rf $SANDBOX }
trap cleanup EXIT

fails=0
ok()   { print -P "%F{green}ok%f   $1" }
fail() { print -P "%F{red}FAIL%f $1"; (( fails++ )) }
check() { local d=$1; shift; if "$@"; then ok $d; else fail $d; fi }
gq() { grep "$@" >/dev/null 2>&1 }
not() { ! "$@" }

# the repository the worktrees come from, cloned from a local "GitHub"
origin=$SANDBOX/origin.git repo=$SANDBOX/app
git init -q --bare -b main $origin
git clone -q $origin $SANDBOX/seed 2>/dev/null
( cd $SANDBOX/seed && git commit -q --allow-empty -m init && git push -q origin main )
git clone -q $origin $repo 2>/dev/null
# branches that appear on the remote after the clone, as a pull request's would
( cd $SANDBOX/seed
  git checkout -q -b feat/login && git commit -q --allow-empty -m login && git push -q origin feat/login
  git checkout -q -b fork-work main && git commit -q --allow-empty -m forkwork
  git push -q origin HEAD:refs/pull/9/head
  git checkout -q main )
login_tip=$(git -C $origin rev-parse feat/login)
fork_tip=$(git -C $origin rev-parse refs/pull/9/head)

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
  repos/acme/widgets/pulls/*) f=$FIX/pull-${ep##*/}.json ;;
  repos/acme/widgets/issues/*) f=$FIX/issue-${ep##*/}.json ;;
  *) echo "gh: HTTP 404" >&2; exit 1 ;;
esac
[ -r "$f" ] || { echo "gh: HTTP 404" >&2; exit 1; }
jq -r "$jqx" "$f"
STUB
chmod +x $SANDBOX/stub/gh
export FIX=$SANDBOX/fix GH_LOG=$SANDBOX/gh.log
path=($SANDBOX/stub $path); rehash

pr()    { print -r -- "{\"head\":{\"ref\":\"$2\",\"repo\":{\"full_name\":\"$3\"}}}" >$FIX/pull-$1.json }
issue() { jq -n --arg t "$2" --argjson pr "${3:-false}" '{title:$t} + (if $pr then {pull_request:{}} else {} end)' >$FIX/issue-$1.json }
pr 7 feat/login acme/widgets
pr 8 feat/deleted acme/widgets
pr 9 feature other/widgets
print -r -- '{"head":{"ref":"x","repo":null}}' >$FIX/pull-11.json
pr 12 -evil acme/widgets
pr 13 'a..b' acme/widgets
pr 14 'x y' acme/widgets
issue 21 'Fix: the Login page crashes!! (urgent)'
issue 22 ''
issue 23 'A very long title that goes on and on well past the limit of forty characters'
issue 24 'This is really a pull request' true
issue 25 '$(touch '$SANDBOX'/pwned) ; `touch '$SANDBOX'/pwned2` ../../etc/passwd'
issue 26 $'Tab\there and\nnewline \e[31mred\e[0m'
issue 27 'ÄÖÜ ünïcode ✓ 日本語'
issue 28 '---'
issue 29 "$(printf 'a%.0s' {1..39}) tail"
pr 15 feat/login Acme/Widgets

wt() { print -r -- $LAZYFLEET_WORKTREES/app/$1 }
new() { out=$(_lazyfleet_main new -r $repo --no-open "$@" 2>$SANDBOX/err); rc=$?; err=$(<$SANDBOX/err) }
branch_of() { git -C $1 branch --show-current }
calls() { [[ -e $GH_LOG ]] && wc -l <$GH_LOG | tr -d ' ' || print 0 }
removewt() { git -C $repo worktree remove --force $1 2>/dev/null }
nothing_new() { [[ -z $(print -l $LAZYFLEET_WORKTREES/app/*(N)) ]] }

# --- a pull request from this repository
new --pr 7
check 'new --pr works' test $rc = 0
check 'it makes the worktree of the pull request branch' test -d $(wt feat-login)
check 'the worktree is on the pull request branch' test "$(branch_of $(wt feat-login))" = feat/login
check 'it has the pull request commit' test "$(git -C $(wt feat-login) rev-parse HEAD)" = $login_tip
check 'the branch tracks origin' test "$(git -C $(wt feat-login) rev-parse --abbrev-ref @{u})" = origin/feat/login
check 'it prints the path' test "$out" = $(wt feat-login)
check 'the summary says where it came from' eval 'gq "from    pull request #7" <<<$err'
check 'gh was asked once, about that pull request' eval 'test "$(<$GH_LOG)" = repos/acme/widgets/pulls/7'
new --pr 7
check 'a second time the worktree already exists' eval 'test $rc = 1 && gq "already exists" <<<$err'
removewt $(wt feat-login)
new --pr 7
check 'once removed, the local branch is reused' eval 'test $rc = 0 && test "$(branch_of $(wt feat-login))" = feat/login'
removewt $(wt feat-login)

# --- a pull request from a fork
rm -f $GH_LOG
new --pr 9
check 'a fork pull request works' test $rc = 0
check 'it gets the local branch pr-9' test "$(branch_of $(wt pr-9))" = pr-9
check 'it has the commit of the pull request' test "$(git -C $(wt pr-9) rev-parse HEAD)" = $fork_tip
check 'it does not claim to track anything' eval '! git -C $(wt pr-9) rev-parse --abbrev-ref @{u} 2>/dev/null'
removewt $(wt pr-9)
git -C $repo update-ref refs/heads/pr-9 $login_tip   # a branch of that name, somewhere else
new --pr 9
check 'an existing pr-9 branch is used as it is' eval 'test $rc = 0 && test "$(git -C $(wt pr-9) rev-parse HEAD)" = $login_tip'
removewt $(wt pr-9); git -C $repo branch -q -D pr-9
new --pr 11
check 'a pull request whose repository is gone is fetched from the fork ref' eval 'test $rc = 1 && gq "could not fetch pull request #11" <<<$err'

# the repository name is compared without regard to case
rm -rf $LAZYFLEET_WORKTREES; git -C $repo worktree prune
new --pr 15
check 'a head repository named in other letters is still this repository' eval 'test $rc = 0 && test "$(branch_of $(wt feat-login))" = feat/login'
removewt $(wt feat-login)

# --- pull requests that cannot be used
rm -rf $LAZYFLEET_WORKTREES
new --pr 8
check 'a deleted branch is an error' eval 'test $rc = 1 && gq "could not fetch branch feat/deleted of pull request #8" <<<$err'
check 'it makes nothing' nothing_new
for n in 12 13 14; do
  new --pr $n
  check "pull request $n: a branch name git refuses is an error" eval 'test $rc = 1 && gq "branch name git does not accept" <<<$err'
done
check 'none of them made anything' nothing_new
new --pr 99
check 'a pull request that does not exist' eval 'test $rc = 1 && gq "could not read pull request #99" <<<$err'

# --- bad numbers never reach gh
rm -f $GH_LOG
for n in abc 0 -1 1e3 '7; touch x' '' 1234567890 $'7\e[31m'; do
  new --pr "$n"
  check "--pr '${n//[[:cntrl:]]/?}' is refused" eval 'test $rc = 1 && gq "not a number" <<<$err'
  check "its error shows no escape character" eval '! gq $'"'"'\e'"'"' <<<$err'
done
new --issue abc
check '--issue abc is refused too' eval 'test $rc = 1 && gq "not a number" <<<$err'
check 'gh was never asked' test "$(calls)" = 0

# --- an issue
new --issue 21
check 'new --issue works' test $rc = 0
check 'the branch is named after the number and title' test "$(branch_of $(wt issue-21-fix-the-login-page-crashes-urgent))" = issue-21-fix-the-login-page-crashes-urgent
check 'it starts from the default branch' test "$(git -C $(wt issue-21-fix-the-login-page-crashes-urgent) rev-parse HEAD)" = "$(git -C $repo rev-parse origin/HEAD)"
check 'the summary says where it came from' eval 'gq "from    issue #21" <<<$err'
removewt $(wt issue-21-fix-the-login-page-crashes-urgent)
new --issue 21
check 'once removed, the branch is reused' test $rc = 0
removewt $(wt issue-21-fix-the-login-page-crashes-urgent)
new --issue 22
check 'an issue without a title is just issue-22' test "$(branch_of $(wt issue-22))" = issue-22
new --issue 23
check 'a long title is cut at 40 characters' test "$(branch_of $(wt issue-23-a-very-long-title-that-goes-on-and-on-we))" = issue-23-a-very-long-title-that-goes-on-and-on-we
new --issue 25
b=$(git -C $repo for-each-ref --format='%(refname:short)' 'refs/heads/issue-25*')
check 'a hostile title only becomes letters, digits and dashes' eval '[[ $b == issue-25-[a-z0-9-]## ]]'
check 'it ran nothing' not test -e $SANDBOX/pwned
check 'it ran nothing (backticks)' not test -e $SANDBOX/pwned2
new --issue 26
b=$(git -C $repo for-each-ref --format='%(refname:short)' 'refs/heads/issue-26*')
check 'control characters in a title are gone' eval '[[ $b == issue-26-[a-z0-9-]## ]]'
new --issue 27
b=$(git -C $repo for-each-ref --format='%(refname:short)' 'refs/heads/issue-27*')
check 'non-ASCII letters are dropped, the rest stays valid' eval '[[ $b == issue-27 || $b == issue-27-[a-z0-9-]## ]]'
new --issue 28
check 'a title of only dashes is just issue-28' test "$(branch_of $(wt issue-28))" = issue-28
new --issue 29
check 'a cut that ends on a dash drops the dash' test "$(branch_of $(wt issue-29-$(printf 'a%.0s' {1..39})))" = issue-29-$(printf 'a%.0s' {1..39})
new --issue 24
check 'an issue that is a pull request is pointed to --pr' eval 'test $rc = 1 && gq "#24 is a pull request: use --pr 24" <<<$err'
new --issue 99
check 'an issue that does not exist' eval 'test $rc = 1 && gq "could not read issue #99" <<<$err'
rm -rf $LAZYFLEET_WORKTREES; git -C $repo worktree prune; git -C $repo branch -q -D issue-21-fix-the-login-page-crashes-urgent
new --issue 21 -b feat/login
check '-b sets what an issue starts from' eval 'test $rc = 0 && test "$(git -C $(wt issue-21-fix-the-login-page-crashes-urgent) rev-parse HEAD)" = $(git -C $repo rev-parse feat/login 2>/dev/null || git -C $repo rev-parse origin/feat/login)'

# --- the arguments
new --pr 7 --issue 21
check 'both --pr and --issue is refused' eval 'test $rc = 1 && gq "not both" <<<$err'
new feat/x --pr 7
check 'a branch and --pr is refused' eval 'test $rc = 1 && gq "not both" <<<$err'
new --issue 21 feat/x
check 'a branch and --issue is refused' eval 'test $rc = 1 && gq "not both" <<<$err'
new
check 'nothing at all shows the usage' eval 'test $rc = 1 && gq "usage: lazyfleet new <branch> | --pr <number> | --issue <number>" <<<$err'
new --pr=7
check '--pr=7 works like --pr 7' test $rc = 0

# --- what is needed
removewt $(wt feat-login)
new_without_gh() { ( unset 'commands[gh]'; _lazyfleet_main new -r $repo --no-open --pr 7 2>&1 ) }
out=$(new_without_gh)
check 'without gh it says so' eval 'gq "needs gh" <<<$out'
git() { command git "$@" }   # origin is no longer on GitHub
new --pr 7
check 'without a GitHub remote it says so' eval 'test $rc = 1 && gq "needs a GitHub remote called origin" <<<$err'
git() { if [[ $* == *'remote get-url origin'* ]]; then print -r -- https://github.com/acme/widgets.git; else command git "$@"; fi }
GH_FAIL=1 new --pr 7
check 'a failing gh is reported' eval 'test $rc = 1 && gq "could not read pull request #7" <<<$err'

check 'the help lists --pr and --issue' eval '_lazyfleet_help | gq -- "--pr <number>"'
check 'completion offers them' eval 'gq -- "--pr" $ROOT/_lazyfleet && gq -- "--issue" $ROOT/_lazyfleet'

if (( fails )); then print -P "%F{red}$fails failed%f"; exit 1; fi
print -P "%F{green}all passed%f"
