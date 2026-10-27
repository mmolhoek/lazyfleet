#!/usr/bin/env -S zsh -f
# Tests for the pull request / CI marks. No network: gh is a stub that serves
# fixture JSON (shaped like GitHub's REST responses) and runs the real --jq
# programs through jq, so the JSON handling is tested too.

ROOT=${0:A:h:h}
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg LAZYFLEET_WORKTREES=$SANDBOX/wt TMPDIR=$SANDBOX/tmp
export TMUX_TMPDIR=$SANDBOX GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p $HOME $TMPDIR $SANDBOX/stub $SANDBOX/fix
unset TMUX LAZYFLEET_PR_STATUS LAZYFLEET_AGENT_ICONS
export LAZYFLEET_TMUX="tmux -L lazyfleet-pr-$$" SHELL=${commands[zsh]}
export LAZYFLEET_AGENT_ICONS=off
source $ROOT/lazyfleet.zsh
cleanup() { _lazyfleet_tmux kill-server 2>/dev/null; rm -rf $SANDBOX }
trap cleanup EXIT

fails=0
ok()   { print -P "%F{green}ok%f   $1" }
fail() { print -P "%F{red}FAIL%f $1"; (( fails++ )) }
check() { local d=$1; shift; if "$@"; then ok $d; else fail $d; fi }
skip() { print -P "%F{yellow}skip%f $1 ($2)" }
gq() { grep "$@" >/dev/null 2>&1 }
not() { ! "$@" }
retry() { local i; for i in {1..60}; do eval "$1" && return 0; sleep 0.1; done; return 1 }
plain() { sed 's/\x1b\[[0-9;]*m//g' }

# ---------------------------------------------------------------- remotes
slug_of() {  # print the slug of a repo whose origin is $1 (none: no origin)
  local d=$(mktemp -d $SANDBOX/g.XXXXXX)
  git init -q $d
  [[ $# -gt 0 ]] && git -C $d remote add origin "$1"
  _lazyfleet_ghslug $d && print -r -- $REPLY
}
accepts() { test "$(slug_of "$1")" = "$2" }
rejects() { test -z "$(slug_of "$@")" }

for pair in 'https://github.com/acme/widgets|acme/widgets' \
            'https://github.com/acme/widgets.git|acme/widgets' \
            'https://github.com/acme/widgets/|acme/widgets' \
            'http://github.com/acme/widgets.git|acme/widgets' \
            'https://user:ghp_secret@github.com/acme/widgets.git|acme/widgets' \
            'https://github.com:443/acme/widgets|acme/widgets' \
            'https://www.github.com/acme/widgets|acme/widgets' \
            'https://GitHub.com/Acme/Widgets.git|Acme/Widgets' \
            'ssh://git@github.com/acme/widgets.git|acme/widgets' \
            'ssh://git@github.com:22/acme/widgets.git|acme/widgets' \
            'git://github.com/acme/widgets.git|acme/widgets' \
            'git@github.com:acme/widgets.git|acme/widgets' \
            'github.com:acme/widgets|acme/widgets' \
            'git@github.com:acme/my.repo-name_2.git|acme/my.repo-name_2'; do
  check "remote ${pair%%|*}" accepts "${pair%%|*}" "${pair##*|}"
done
for url in https://gitlab.com/acme/widgets.git git@gitlab.com:acme/widgets.git \
           https://github.example.com/acme/widgets https://evil.com/github.com/acme/widgets \
           https://github.com.evil.com/acme/widgets https://github.com/acme \
           https://github.com/acme/widgets/extra 'https://github.com/../widgets' 'https://github.com/acme/..' \
           'https://github.com/ac me/widgets' /local/path/repo ../relative file:///srv/git/widgets.git \
           'https://github.com/acme/wid$(touch x)gets' 'git@github.com:acme/wid;gets' 'C:\repo'; do
  check "rejects remote $url" rejects "$url"
done
check 'rejects a repo without an origin' rejects
check 'a token in the remote url never reaches the slug' not eval 'slug_of https://user:ghp_secret@github.com/acme/widgets.git | gq secret'

# ---------------------------------------------------------------- setting
check 'disabled without gh' eval '( path=(); unhash gh 2>/dev/null; ! _lazyfleet_pr_enabled )'
cat >$SANDBOX/stub/gh <<'STUB'
#!/bin/sh
# gh api ENDPOINT [--jq PROGRAM], served from $FIX; every call is logged
[ "$1" = api ] || exit 2
ep=$2; shift 2
jqx=.
while [ $# -gt 0 ]; do case $1 in --jq|-q) jqx=$2; shift 2 ;; *) shift ;; esac; done
echo "$ep" >>"$GH_LOG"
[ -n "$GH_SLEEP" ] && sleep "$GH_SLEEP"
[ -n "$GH_FAIL" ] && { echo "gh: HTTP 401" >&2; exit 1; }
case $ep in
  repos/acme/widgets/pulls\?*) f=$FIX/pulls.json ;;
  repos/acme/widgets/commits/*/check-runs*)
    [ -n "$GH_FAIL_CI" ] && { echo "gh: HTTP 500" >&2; exit 1; }
    sha=${ep#*/commits/}; sha=${sha%%/*}; f=$FIX/checks-$sha.json ;;
  repos/acme/widgets/commits/*/status*)
    [ -n "$GH_FAIL_CI" ] && { echo "gh: HTTP 500" >&2; exit 1; }
    sha=${ep#*/commits/}; sha=${sha%%/*}; f=$FIX/status-$sha.json ;;
  *) echo "gh: HTTP 404" >&2; exit 1 ;;
esac
[ -r "$f" ] || { echo "gh: HTTP 404" >&2; exit 1; }
jq -r "$jqx" "$f"
STUB
chmod +x $SANDBOX/stub/gh
export FIX=$SANDBOX/fix GH_LOG=$SANDBOX/gh.log
path=($SANDBOX/stub $path); rehash
check 'enabled with gh' _lazyfleet_pr_enabled
check 'disabled by the env var' eval 'LAZYFLEET_PR_STATUS=off _lazyfleet_pr_enabled; test $? != 0'
mkdir -p $XDG_CONFIG_HOME/lazyfleet; print 'pr_status=off' >$XDG_CONFIG_HOME/lazyfleet/config
check 'disabled in the config' not _lazyfleet_pr_enabled
check 'the env var wins over the config' eval 'LAZYFLEET_PR_STATUS=on _lazyfleet_pr_enabled'
rm -rf $XDG_CONFIG_HOME/lazyfleet

# ---------------------------------------------------------------- CI verdicts
ci() { _lazyfleet_pr_ci "$1" "$2"; print -r -- $REPLY }
check 'nothing at all is none' test "$(ci '' '')" = none
check 'no checks and a "0 pending" status is none, not pending' test "$(ci '' '0 pending')" = none
check 'a zero count ignores even a failure state' test "$(ci '' '0 failure')" = none
check 'passing checks' test "$(ci 'completed/success completed/success' '')" = pass
check 'skipped and neutral pass' test "$(ci 'completed/skipped completed/neutral' '')" = pass
for c in failure timed_out cancelled action_required startup_failure; do
  check "a $c check fails" test "$(ci "completed/success completed/$c" '')" = fail
done
check 'a running check is pending' test "$(ci 'completed/success in_progress/-' '')" = pending
check 'a queued check is pending' test "$(ci 'queued/-' '')" = pending
check 'a failure beats pending' test "$(ci 'in_progress/- completed/failure' '')" = fail
check 'pending beats pass' test "$(ci 'completed/success queued/-' '')" = pending
check 'a stale check is ignored' test "$(ci 'completed/stale' '')" = none
check 'an unknown conclusion is pending' test "$(ci 'completed/surprise' '')" = pending
check 'a passing status' test "$(ci '' '3 success')" = pass
check 'a failing status' test "$(ci '' '2 failure')" = fail
check 'an errored status' test "$(ci '' '1 error')" = fail
check 'a pending status' test "$(ci '' '1 pending')" = pending
check 'passing checks with a failing status fail' test "$(ci 'completed/success' '2 failure')" = fail
check 'passing checks with a pending status are pending' test "$(ci 'completed/success' '1 pending')" = pending
check 'a passing status without checks passes' test "$(ci '' '1 success')" = pass
check 'a garbled status is ignored' test "$(ci 'completed/success' 'x y')" = pass

# ---------------------------------------------------------------- marks
ESC=$'\e'
mk() { _lazyfleet_pr_mark "$@"; print -r -- $REPLY }
check 'open, passing' test "$(mk 12 open pass -p)" = '#12 ✓'
check 'open, failing' test "$(mk 12 open fail -p)" = '#12 ✗'
check 'open, running' test "$(mk 12 open pending -p)" = '#12 …'
check 'open, no checks' test "$(mk 12 open none -p)" = '#12'
check 'open, checks not looked up' test "$(mk 12 open - -p)" = '#12'
check 'draft' test "$(mk 12 draft pass -p)" = '#12 draft'
check 'merged' test "$(mk 12 merged - -p)" = '#12 merged'
check 'closed' test "$(mk 12 closed - -p)" = '#12 closed'
check 'an unknown state shows nothing' eval '! _lazyfleet_pr_mark 12 weird -; test -z "$REPLY"'
check 'passing is green' eval 'mk 1 open pass | gq -F "${ESC}[32m"'
check 'failing is red' eval 'mk 1 open fail | gq -F "${ESC}[31m"'
check 'running is yellow' eval 'mk 1 open pending | gq -F "${ESC}[33m"'
check 'merged is magenta' eval 'mk 1 merged - | gq -F "${ESC}[35m"'
check 'no checks has no colour at all' eval '! mk 1 open none | gq -F "$ESC"'
check 'colours leave the text readable' test "$(mk 7 open fail | plain)" = '#7 ✗'

# ---------------------------------------------------------------- fixtures
SHA() { printf '%040d' $1 }
pr() {  # number state draft merged ref sha repo titleJSON
  local repo=$7
  jq -n --argjson n $1 --arg st $2 --argjson dr $3 --arg mg "$4" --arg ref "$5" --arg sha "$6" --arg repo "$repo" --argjson title "$8" \
    '{number:$n, state:$st, draft:$dr, merged_at:(if $mg=="" then null else $mg end), title:$title,
      html_url:"https://github.com/acme/widgets/pull/\($n)",
      head:{ref:$ref, sha:$sha, repo:(if $repo=="" then null else {full_name:$repo} end)}}'
}
checks() {  # sha status/conclusion...   ("-" for a conclusion that is null)
  local sha=$1; shift
  print -r -- '[]' | jq --args '[$ARGS.positional[] | split("/") | {status:.[0], conclusion:(if .[1]=="-" then null else .[1] end)}]
    | {total_count:length, check_runs:.}' "$@" >$FIX/checks-$sha.json
}
cstatus() { jq -n --argjson c $2 --arg st $3 '{total_count:$c, state:$st}' >$FIX/status-$1.json }
make_fixtures() {
  EVIL='"evil\u001b[31m red\ttab\nnewline \u009b2J \u202e bidi back\\slash"'
  {
    pr 50 open false '' feat/open-pass $(SHA 99) someone/widgets '"fork, listed first"'
    pr 30 open false '' feat/open-pass $(SHA 1) acme/widgets '"Add pass"'
    pr 31 open false '' feat/open-fail $(SHA 2) acme/widgets '"Add fail"'
    pr 32 open false '' feat/open-pending $(SHA 3) acme/widgets '"Add pending"'
    pr 33 open false '' feat/open-none $(SHA 4) acme/widgets '"Add none"'
    pr 34 open false '' feat/legacy-fail $(SHA 5) acme/widgets '"Add legacy"'
    pr 35 open true '' feat/draft $(SHA 6) acme/widgets '"Add draft"'
    pr 36 closed false 2026-01-01T00:00:00Z feat/merged $(SHA 7) acme/widgets '"Add merged"'
    pr 37 closed false '' feat/closed $(SHA 8) acme/widgets '"Add closed"'
    pr 40 closed false 2026-01-02T00:00:00Z feat/redo $(SHA 9) acme/widgets '"old try, merged"'
    pr 41 open false '' feat/redo $(SHA 10) acme/widgets '"new try"'
    pr 42 closed false '' feat/redo2 $(SHA 11) acme/widgets '"closed, more recent"'
    pr 43 closed false 2026-01-03T00:00:00Z feat/redo2 $(SHA 12) acme/widgets '"merged, older"'
    pr 44 open false '' feat/same $(SHA 13) acme/widgets '"first of two"'
    pr 45 open false '' feat/same $(SHA 14) acme/widgets '"second of two"'
    pr 51 open false '' feat/ghost $(SHA 15) '' '"deleted fork"'
    pr 52 open false '' feat/not-checked-out $(SHA 16) Acme/Widgets '"nobody has a worktree for this, and the repo name has other case"'
    pr 53 open false '' feat/evil $(SHA 17) acme/widgets "$EVIL"
    pr 54 open false '' 'feat/odd]name$x' $(SHA 18) acme/widgets '"odd branch name"'
  } | jq -s . >$FIX/pulls.json
  checks $(SHA 1) completed/success completed/success;            # 30: no status fixture at all (404)
  checks $(SHA 2) completed/success completed/failure;            cstatus $(SHA 2) 0 pending
  checks $(SHA 3) completed/success in_progress/-;                cstatus $(SHA 3) 0 pending
  checks $(SHA 4);                                                cstatus $(SHA 4) 0 pending
  checks $(SHA 5);                                                cstatus $(SHA 5) 2 failure
  checks $(SHA 6) completed/success;                              cstatus $(SHA 6) 0 pending
  checks $(SHA 10) completed/success;                             cstatus $(SHA 10) 0 pending
  checks $(SHA 13) completed/success;                             cstatus $(SHA 13) 0 pending
  checks $(SHA 17) completed/skipped completed/neutral;           cstatus $(SHA 17) 0 pending
  checks $(SHA 18) completed/success;                             cstatus $(SHA 18) 0 pending
}
make_fixtures
check 'the fixtures are valid JSON' eval 'jq -e . $FIX/pulls.json $FIX/checks-$(SHA 1).json >/dev/null'

WANT=(feat/open-pass feat/open-fail feat/open-pending feat/open-none feat/legacy-fail feat/draft feat/merged feat/closed
      feat/redo feat/redo2 feat/same feat/ghost feat/evil 'feat/odd]name$x' main)
_lazyfleet_pr_cachefile acme/widgets; CACHE=$REPLY
: >$GH_LOG
_lazyfleet_pr_fetch acme/widgets $CACHE $WANT; rc=$?
check 'the fetch succeeds' test $rc = 0
check 'the first fetch reports a change' test "$REPLY" = changed
check 'the cache has a header' eval 'head -1 $CACHE | gq -E "^#lazyfleet-pr 1 [0-9]+ ok$"'
typeset -A prs
_lazyfleet_pr_read acme/widgets
check 'reading reports a fresh cache' test "$REPLY" -ge 0 -a "$REPLY" -le 5
field() { local -a f; f=("${(@ps:\t:)prs[acme/widgets:$1]}"); print -r -- $f[$2] }   # 1 number 2 state 3 ci 4 url 5 title
for spec in 'feat/open-pass|30|open|pass' 'feat/open-fail|31|open|fail' 'feat/open-pending|32|open|pending' \
            'feat/open-none|33|open|none' 'feat/legacy-fail|34|open|fail' 'feat/draft|35|draft|pass' \
            'feat/merged|36|merged|-' 'feat/closed|37|closed|-' 'feat/redo|41|open|pass' 'feat/redo2|43|merged|-' \
            'feat/same|44|open|pass' 'feat/not-checked-out|52|open|-' 'feat/evil|53|open|pass' 'feat/odd]name$x|54|open|pass'; do
  b=${spec%%|*}; rest=${spec#*|}
  check "$b: #${rest%%|*}, ${${rest#*|}%%|*}, ci ${rest##*|}" test "$(field $b 1) $(field $b 2) $(field $b 3)" = "${rest%%|*} ${${rest#*|}%%|*} ${rest##*|}"
done
check 'a fork pull request is not taken for the branch of the same name' test "$(field feat/open-pass 1)" = 30
check 'a deleted fork is ignored' test -z "$prs[acme/widgets:feat/ghost]"
check 'the url is kept' test "$(field feat/open-pass 4)" = https://github.com/acme/widgets/pull/30
check 'a missing status endpoint still gives a verdict from the checks' test "$(field feat/open-pass 3)" = pass
check 'a branch with no worktree gets no CI lookup' not gq "$(SHA 16)" $GH_LOG
check 'branches with a worktree do' gq "commits/$(SHA 2)/check-runs" $GH_LOG
check 'a merged pull request gets no CI lookup' not gq "commits/$(SHA 7)/" $GH_LOG
title=$(field feat/evil 5)
check 'a hostile title has no escape character' not eval '[[ $title == *$'"'"'\e'"'"'* ]]'
check 'a hostile title has no C1 control character' not eval '[[ $title == *$'"'"'\xc2\x9b'"'"'* ]]'
check 'a hostile title has no bidi override' not eval '[[ $title == *$'"'"'\xe2\x80\xae'"'"'* ]]'
check 'a hostile title has no tab or newline' not eval '[[ $title == *$'"'"'\t'"'"'* || $title == *$'"'"'\n'"'"'* ]]'
check 'the readable part of a hostile title survives' eval '[[ $title == *"evil"*"tab"*"newline"*"back\\slash" ]]'
check 'the cache file holds no control character but tabs and newlines' not eval 'LC_ALL=C tr -d "\t\n" <$CACHE | LC_ALL=C grep -q "[[:cntrl:]]"'

: >$GH_LOG
_lazyfleet_pr_fetch acme/widgets $CACHE $WANT
check 'fetching the same data again reports no change' test "$REPLY" = same
jq '(.[] | select(.number==41) | .title) = "new try, renamed"' $FIX/pulls.json >$FIX/pulls.new && mv $FIX/pulls.new $FIX/pulls.json
_lazyfleet_pr_fetch acme/widgets $CACHE $WANT
check 'a changed title is a change' test "$REPLY" = changed
checks $(SHA 3) completed/success completed/success
_lazyfleet_pr_fetch acme/widgets $CACHE $WANT
check 'a check that finished is a change' test "$REPLY" = changed
prs=(); _lazyfleet_pr_read acme/widgets
check 'and the verdict follows' test "$(field feat/open-pending 3)" = pass

# a failed fetch keeps the old rows and moves only the time
sed -i '1s/.*/#lazyfleet-pr 1 1000 ok/' $CACHE
rows_before=$(tail -n +2 $CACHE)
GH_FAIL=1 _lazyfleet_pr_fetch acme/widgets $CACHE $WANT; rc=$?
check 'a failed fetch fails' test $rc != 0
check 'a failed fetch reports no change' test "$REPLY" = same
check 'it keeps the old rows' test "$(tail -n +2 $CACHE)" = "$rows_before"
check 'it is marked as failed' eval 'head -1 $CACHE | gq -E "^#lazyfleet-pr 1 [0-9]+ fail$"'
prs=(); _lazyfleet_pr_read acme/widgets
check 'and its time moved, so it is not retried at once' test "$REPLY" -le 5
check 'the old rows are still readable' test "$(field feat/open-pass 1)" = 30
rm -f $CACHE
GH_FAIL=1 _lazyfleet_pr_fetch acme/widgets $CACHE $WANT
check 'a failed first fetch leaves an empty, failed cache' eval 'test "$(wc -l <$CACHE | tr -d " ")" = 1 && head -1 $CACHE | gq " fail$"'
prs=(); check 'which reads as no pull requests' eval '_lazyfleet_pr_read acme/widgets && test $#prs = 0'
rm -f $CACHE
GH_FAIL_CI=1 _lazyfleet_pr_fetch acme/widgets $CACHE $WANT
prs=(); _lazyfleet_pr_read acme/widgets
check 'failing CI lookups leave the pull requests, without a verdict' test "$(field feat/open-fail 1) $(field feat/open-fail 3)" = '31 none'

# the cap on CI lookups
{ for n in {1..30}; do pr $((100+n)) open false '' feat/many-$n $(SHA $((200+n))) acme/widgets "\"many $n\""; done } | jq -s . >$FIX/pulls.json
: >$GH_LOG; rm -f $CACHE
_lazyfleet_pr_fetch acme/widgets $CACHE feat/many-{1..30}
check 'at most 25 pull requests are asked about their checks' test "$(grep -c check-runs $GH_LOG)" = 25
check 'and all 30 are listed' test "$(tail -n +2 $CACHE | wc -l | tr -d ' ')" = 30

# ---------------------------------------------------------------- reading
f=$CACHE
write() { print -r -- "$1" >|$f; shift; (( $# )) && print -rl -- "$@" >>$f }
now=$EPOCHSECONDS
tab=$'\t'
prs=(); write "#lazyfleet-pr 1 $(( now - 100 )) ok" "feat/a${tab}7${tab}open${tab}pass${tab}https://x/7${tab}title"
check 'reads a hand-written cache' eval '_lazyfleet_pr_read acme/widgets && test "$(field feat/a 1)" = 7'
check 'the age is the time since the attempt' test "$REPLY" -ge 100 -a "$REPLY" -le 105
prs=(); write "#lazyfleet-pr 2 $now ok" "feat/a${tab}7${tab}open${tab}pass${tab}u${tab}t"
check 'an unknown cache version is not read' eval '! _lazyfleet_pr_read acme/widgets; test $#prs = 0'
prs=(); write "garbage" "feat/a${tab}7${tab}open${tab}pass${tab}u${tab}t"
check 'a garbled header is not read' eval '! _lazyfleet_pr_read acme/widgets; test $#prs = 0'
prs=(); write "#lazyfleet-pr 1 soon ok" "feat/a${tab}7${tab}open${tab}pass${tab}u${tab}t"
check 'a non-numeric time is not read' eval '! _lazyfleet_pr_read acme/widgets; test $#prs = 0'
prs=(); write "#lazyfleet-pr 1 $now ok" "feat/a${tab}7${tab}open" "feat/b${tab}8${tab}open${tab}none${tab}u${tab}t"
check 'a short row is skipped, the next one read' eval '_lazyfleet_pr_read acme/widgets; test -z "$prs[acme/widgets:feat/a]" -a -n "$prs[acme/widgets:feat/b]"'
prs=(); write "#lazyfleet-pr 1 $now ok" "feat/c${tab}9${tab}open${tab}none${tab}u${tab}bad"$'\e[31m'"title"
check 'control characters in a cached title are stripped on reading' not eval '_lazyfleet_pr_read acme/widgets; [[ $(field feat/c 5) == *$'"'"'\e'"'"'* ]]'
prs=(); rm -f $f
check 'no cache is not read' eval '! _lazyfleet_pr_read acme/widgets'
prs=(); write "#lazyfleet-pr 1 $now ok" "feat/a${tab}7${tab}open${tab}pass${tab}u${tab}t"
check 'repo names are matched without regard to case' eval '_lazyfleet_pr_read Acme/WIDGETS && test -n "$prs[acme/widgets:feat/a]"'


# ---------------------------------------------------------------- rows, refresh, preview
make_fixtures
repo=$SANDBOX/src/widgets
mkdir -p $repo && git -C $repo init -q -b main && print x >$repo/f && git -C $repo add -A && git -C $repo commit -qm init
git -C $repo remote add origin git@github.com:acme/widgets.git
for b in feat/open-pass feat/open-fail feat/open-pending feat/open-none feat/merged feat/evil; do
  git -C $repo worktree add -q -b $b $LAZYFLEET_WORKTREES/widgets/${b//\//-}
done
git -C $repo worktree add -q --detach $LAZYFLEET_WORKTREES/widgets/detached
_lazyfleet_add $repo >/dev/null
_lazyfleet_tmux new-session -d -s keepalive
wtdir() { print -r -- $LAZYFLEET_WORKTREES/widgets/${1//\//-} }
POSTLOG=$SANDBOX/post.log; : >$POSTLOG
_lazyfleet_fzfpost() { print -r -- "$1" >>$POSTLOG }     # what the detached job tells fzf
_lazyfleet_pr_cachefile acme/widgets; CACHE=$REPLY
setage() { sed -i "1s/.*/#lazyfleet-pr 1 $(( EPOCHSECONDS - $1 )) ok/" $CACHE }   # make the cache $1 seconds old
rowfor() { grep -F "$1" <<<"$rows" | grep -F "${2:-widgets}" }
idle() { retry '[[ ! -d $CACHE.lock ]]' }

rm -rf ${CACHE:h}; : >$GH_LOG
rows=$(_lazyfleet_rows -p); sleep 0.3
check 'without a cache the rows have no marks' not eval 'gq "#[0-9]" <<<$rows'
check 'a plain pass never calls gh' test ! -s $GH_LOG
check 'rows keep their usual shape' eval 'gq "^w"$'"'"'\t'"'"'"$repo" <<<$rows'

t0=$EPOCHREALTIME
rows=$(GH_SLEEP=1 _lazyfleet_rows -s -p); t1=$EPOCHREALTIME
check 'the status pass does not wait for GitHub' test $(( (t1 - t0) * 10 )) -lt 15
check 'it still starts the refresh' retry 'test -s $GH_LOG'
check 'the refresh writes the cache' retry '[[ -s $CACHE ]]'
check 'the refresh finishes and releases its lock' idle
check 'it has the TUI reload when it found something' retry 'gq "transform(.*_prdone)" $POSTLOG'
check 'and tells it once' test "$(wc -l <$POSTLOG | tr -d ' ')" = 1

rows=$(_lazyfleet_rows -p)
check 'passing checks show #30 ✓' eval 'rowfor feat/open-pass | gq "#30 ✓$"'
check 'failing checks show #31 ✗' eval 'rowfor feat/open-fail | gq "#31 ✗$"'
check 'running checks show #32 …' eval 'rowfor feat/open-pending | gq "#32 …$"'
check 'no checks show just #33' eval 'rowfor feat/open-none | gq "#33$"'
check 'a merged pull request says so' eval 'rowfor feat/merged | gq "#36 merged$"'
check 'the main branch has no mark' not eval 'rowfor " main " | gq "#"'
check 'a detached worktree has no mark' not eval 'grep -F detached <<<$rows | gq "#"'
check 'the mark comes after the branch' eval 'rowfor feat/open-pass | gq "feat/open-pass .*#30"'
check 'the coloured rows carry the colour' eval '_lazyfleet_rows | grep -F feat/open-pass | gq -F "${ESC}[32m#30 ✓"'
check 'the status pass shows the marks too' eval '_lazyfleet_rows -s -p | grep -F feat/open-pass | gq "#30 ✓$"'
check 'a hostile title does not touch the rows' not eval '_lazyfleet_rows | gq "red tab"'
idle

# a fresh cache is not refreshed
: >$GH_LOG; : >$POSTLOG
_lazyfleet_rows -s -p >/dev/null; sleep 0.8
check 'a fresh cache is left alone' test ! -s $GH_LOG

# a stale cache is, quietly when nothing changed
setage 200; : >$GH_LOG; : >$POSTLOG
_lazyfleet_rows -s -p >/dev/null
check 'a stale cache is refreshed' retry 'test -s $GH_LOG'
idle
check 'the refresh moved the time' eval 'head -1 $CACHE | gq -E "^#lazyfleet-pr 1 [0-9]+ ok$" && _lazyfleet_pr_read acme/widgets && test $REPLY -le 5'
check 'unchanged data does not make the TUI reload' test ! -s $POSTLOG

# changed data does
checks $(SHA 2) completed/success completed/success
setage 200; : >$POSTLOG
_lazyfleet_rows -s -p >/dev/null
check 'changed data has the TUI reload' retry 'gq "_prdone" $POSTLOG'
idle
rows=$(_lazyfleet_rows -p)
check 'and the new verdict shows' eval 'rowfor feat/open-fail | gq "#31 ✓$"'

# locks
setage 200; : >$GH_LOG; mkdir $CACHE.lock
_lazyfleet_rows -s -p >/dev/null; sleep 0.8
check 'a refresh in progress is not started twice' test ! -s $GH_LOG
touch -t 200001010000 $CACHE.lock
_lazyfleet_rows -s -p >/dev/null; sleep 0.3
check 'a dead lock is cleared' test ! -d $CACHE.lock
_lazyfleet_rows -s -p >/dev/null
check 'and the next pass refreshes' retry 'test -s $GH_LOG'
idle

# switched off, no gh, not GitHub
setage 200; : >$GH_LOG
rows=$(LAZYFLEET_PR_STATUS=off _lazyfleet_rows -s -p); sleep 0.8
check 'pr_status=off shows no marks' not eval 'gq "#[0-9]" <<<$rows'
check 'pr_status=off does not call gh' test ! -s $GH_LOG
tb=$SANDBOX/nogh; mkdir -p $tb
for t in git tmux ps jq sh cat tail head mkdir mv rm rmdir mktemp touch sleep sed grep cut tr wc date env awk uname find ls ln readlink dirname basename sort chmod; do
  [[ -n ${commands[$t]} ]] && ln -sf ${commands[$t]} $tb/$t
done
rows=$( path=($tb); rehash; _lazyfleet_rows -s -p ); rehash
check 'without gh the rows have no marks' not eval 'gq "#[0-9]" <<<$rows'
check 'without gh the rows still list the worktrees' eval 'gq feat/open-pass <<<$rows'
git -C $repo remote set-url origin https://gitlab.com/acme/widgets.git
rows=$(_lazyfleet_rows -s -p); sleep 0.5
check 'a repo that is not on GitHub has no marks' not eval 'gq "#[0-9]" <<<$rows'
check 'and is not asked about' test ! -s $GH_LOG
git -C $repo remote set-url origin git@github.com:acme/widgets.git
idle

# the TUI's reload
done_for() { FZF_LIST_LABEL="$1" _lazyfleet_prdone }
check 'a worktree list is reloaded, with status' eval 'done_for " Worktrees " | gq "^reload-sync(.*_rows -s)$"'
check 'not while it is loading' test -z "$(done_for ' Worktrees · loading… ')"
check 'not while it checks the status' test -z "$(done_for ' Worktrees · checking status… ')"
check 'not on the windows' test -z "$(done_for ' Windows ')"

# the Details pane
pv() { _lazyfleet_pr_preview $(wtdir $1) | plain }
make_fixtures; rm -f $CACHE; _lazyfleet_pr_fetch acme/widgets $CACHE feat/open-pass feat/open-fail feat/open-pending feat/open-none feat/merged feat/evil
check 'the pane names the pull request and its title' eval 'pv feat/open-pass | gq "^PR #30  Add pass$"'
check 'it gives the state, the checks and the url' eval 'pv feat/open-pass | gq "open · checks passing  https://github.com/acme/widgets/pull/30"'
check 'failing checks' eval 'pv feat/open-fail | gq "checks failing"'
check 'running checks' eval 'pv feat/open-pending | gq "checks running"'
check 'no checks' eval 'pv feat/open-none | gq "no checks"'
check 'a merged pull request has no checks line' eval 'pv feat/merged | gq "merged  https" && ! pv feat/merged | gq checks'
check 'the main worktree has no pull request' test -z "$(_lazyfleet_pr_preview $repo)"
check 'a detached worktree has none' test -z "$(_lazyfleet_pr_preview $LAZYFLEET_WORKTREES/widgets/detached)"
raw=$(_lazyfleet_pr_preview $(wtdir feat/evil))
check 'a hostile title is defanged in the pane' not eval '[[ $raw == *$ESC"[31m"* || $raw == *$'"'"'\xc2\x9b'"'"'* || $raw == *$'"'"'\xe2\x80\xae'"'"'* ]]'
check 'the pane is not stale-flagged when fresh' not eval 'pv feat/open-pass | gq "as of"'
setage 1300
check 'an old cache says how old' eval 'pv feat/open-pass | gq "as of 21 min ago"'
check 'pr_status=off hides the pane section' test -z "$(LAZYFLEET_PR_STATUS=off _lazyfleet_pr_preview $(wtdir feat/open-pass))"
check 'the whole worktree preview includes it' eval '_lazyfleet_preview w $(wtdir feat/open-pass) | plain | gq "PR #30  Add pass"'
rm -f $CACHE
check 'without a cache there is no section' test -z "$(_lazyfleet_pr_preview $(wtdir feat/open-pass))"

(( fails )) && { print -P "\n%F{red}$fails failed%f"; exit 1 }
print -P "\n%F{green}all passed%f"
