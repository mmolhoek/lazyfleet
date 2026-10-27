#!/usr/bin/env -S zsh -f
# Tests for the hand-off keys: e (editor), g (lazygit) and o (the pull request
# in the browser). The tools are stubs that record how they were started; tmux
# is a real, isolated server.

ROOT=${0:A:h:h}
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg LAZYFLEET_WORKTREES=$SANDBOX/wt TMPDIR=$SANDBOX/tmp
export TMUX_TMPDIR=$SANDBOX GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p $HOME $TMPDIR $SANDBOX/stub $SANDBOX/fix
setopt extended_glob
unset TMUX LAZYFLEET_PR_STATUS BROWSER VISUAL EDITOR
export LAZYFLEET_TMUX="tmux -L lazyfleet-handoff-$$" SHELL=${commands[zsh]}
source $ROOT/lazyfleet.zsh
cleanup() { _lazyfleet_tmux kill-server 2>/dev/null; rm -rf $SANDBOX }
trap cleanup EXIT

fails=0
ok()   { print -P "%F{green}ok%f   $1" }
fail() { print -P "%F{red}FAIL%f $1"; (( fails++ )) }
check() { local d=$1; shift; if "$@"; then ok $d; else fail $d; fi }
gq() { grep "$@" >/dev/null 2>&1 }
not() { ! "$@" }
retry() { local i; for i in {1..60}; do eval "$1" && return 0; sleep 0.1; done; return 1 }
plain() { sed 's/\x1b\[[0-9;]*m//g' }

# --- stubs
STUB=$SANDBOX/stub
# an editor: records its arguments and where it runs, then stays open
cat >$STUB/myeditor <<'EOF'
#!/bin/sh
{ printf 'args=%s\n' "$*"; printf 'pwd=%s\n' "$PWD"; } >>"$TOOL_LOG"
sleep 30
EOF
cat >$STUB/lazygit <<'EOF'
#!/bin/sh
{ printf 'lazygit pwd=%s\n' "$PWD"; } >>"$TOOL_LOG"
sleep 30
EOF
# an editor that gives up at once
cat >$STUB/quickeditor <<'EOF'
#!/bin/sh
exit 3
EOF
# a browser: records the arguments, one per line
cat >$STUB/mybrowser <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a" >>"$BROWSER_LOG"; done
EOF
cp $STUB/mybrowser $STUB/xdg-open
chmod +x $STUB/*
export TOOL_LOG=$SANDBOX/tool.log BROWSER_LOG=$SANDBOX/browser.log

cat >$STUB/gh <<'STUB'
#!/bin/sh
[ "$1" = api ] || exit 2
ep=$2; shift 2
jqx=.
while [ $# -gt 0 ]; do case $1 in --jq|-q) jqx=$2; shift 2 ;; *) shift ;; esac; done
echo "$ep" >>"$GH_LOG"
case $ep in
  repos/acme/widgets/pulls\?*) f=$FIX/pulls.json ;;
  *) f=/nonexistent ;;
esac
[ -r "$f" ] || { echo "gh: HTTP 404" >&2; exit 1; }
jq -r "$jqx" "$f"
STUB
chmod +x $STUB/gh
export FIX=$SANDBOX/fix GH_LOG=$SANDBOX/gh.log
path=($STUB $path); rehash

# git is told that origin is on GitHub (nothing else about git changes)
git() { if [[ $* == *'remote get-url origin'* ]]; then print -r -- https://github.com/acme/widgets.git; else command git "$@"; fi }

# attaching needs a terminal: record where it would go
ATTACHED=
_lazyfleet_attach() { ATTACHED+=("$1") }

repo=$SANDBOX/app
git init -q -b main $repo && git -C $repo commit -q --allow-empty -m init
_lazyfleet_add $repo >/dev/null
mkwt() { git -C $repo worktree add -q -b $1 "$LAZYFLEET_WORKTREES/app/$2" 2>/dev/null; print -r -- "$LAZYFLEET_WORKTREES/app/$2" }
winnames() { _lazyfleet_tmux list-windows -t "=$1" -F '#{window_name}' 2>/dev/null }
tools_seen() { [[ -r $TOOL_LOG ]] && cat $TOOL_LOG }

# --- choosing the editor and checking the tools
EDITOR=myeditor _lazyfleet_tool edit
check 'EDITOR is the editor' test "$REPLY" = 'myeditor .'
VISUAL=quickeditor EDITOR=myeditor _lazyfleet_tool edit
check 'VISUAL wins over EDITOR' test "$REPLY" = 'quickeditor .'
EDITOR='myeditor --wait' _lazyfleet_tool edit
check 'an editor with arguments keeps them' test "$REPLY" = 'myeditor --wait .'
_lazyfleet_tool edit
check 'with neither it is vi' test "$REPLY" = 'vi .'
EDITOR=$STUB/myeditor _lazyfleet_tool edit
check 'an editor given by path works' test "$REPLY" = "$STUB/myeditor ."
out=$(EDITOR=no-such-editor _lazyfleet_tool edit 2>&1); rc=$?
check 'an editor that is not there is an error' eval 'test $rc = 1 && gq "editor .no-such-editor. not found" <<<$out'
out=$(EDITOR=/no/such/editor _lazyfleet_tool edit 2>&1); rc=$?
check 'a path that is not there is an error too' test $rc = 1
_lazyfleet_tool lazygit
check 'lazygit is lazygit' test "$REPLY" = lazygit
out=$( ( unset 'commands[lazygit]'; _lazyfleet_tool lazygit ) 2>&1); rc=$?
check 'a missing lazygit says so' eval 'test $rc = 1 && gq "lazygit is not installed" <<<$out'
out=$(_lazyfleet_tool bogus 2>&1); rc=$?
check 'an unknown tool is refused' test $rc = 1

# --- the editor window
w=$(mkwt feat/a feat-a)
export EDITOR=myeditor
ATTACHED=()
_lazyfleet_handoff edit $w; rc=$?
check 'handoff succeeds' test $rc = 0
check 'it makes the worktree session' eval '_lazyfleet_tmux has-session -t "=app/feat-a" 2>/dev/null'
check 'the editor has a window of its own' eval 'winnames app/feat-a | gq "^edit$"'
check 'the editor started in the worktree' retry 'tools_seen | gq -F "pwd=$w"'
check 'the editor was given the directory' retry 'tools_seen | gq "^args=\.$"'
check 'then it switches to the session' test "$ATTACHED" = '=app/feat-a'
check 'the editor window is the current one' eval 'test "$(_lazyfleet_tmux display-message -p -t "=app/feat-a:" "#{window_name}")" = edit'
_lazyfleet_handoff edit $w
check 'a second time reuses the window' test "$(winnames app/feat-a | grep -c '^edit$')" = 1
check 'the editor was started only once' eval 'test "$(tools_seen | grep -c "^args=")" = 1'
check 'and attached again' test "$#ATTACHED" = 2
_lazyfleet_handoff lazygit $w
check 'lazygit gets its own window' eval 'winnames app/feat-a | gq "^lazygit$" && winnames app/feat-a | gq "^edit$"'
check 'lazygit started in the worktree' retry 'tools_seen | gq -F "lazygit pwd=$w"'
check 'lazygit is the current window' eval 'test "$(_lazyfleet_tmux display-message -p -t "=app/feat-a:" "#{window_name}")" = lazygit'
_lazyfleet_handoff edit $w
check 'asking for the editor again shows it' eval 'test "$(_lazyfleet_tmux display-message -p -t "=app/feat-a:" "#{window_name}")" = edit'

# other windows, with awkward names, do not get in the way
_lazyfleet_tmux new-window -d -t "=app/feat-a:" -n 'my edit window'
_lazyfleet_tmux new-window -d -t "=app/feat-a:" -n 'editor'
_lazyfleet_handoff edit $w
check 'windows named like it, but not it, are ignored' test "$(winnames app/feat-a | grep -c '^edit$')" = 1

# the session already has windows; the new one is added, not replacing one
_lazyfleet_tmux kill-session -t "=app/feat-a"
w2=$(mkwt feat/b feat-b)
_lazyfleet_ensure $w2
n=$(_lazyfleet_tmux list-windows -t "=app/feat-b:" | wc -l | tr -d ' ')
_lazyfleet_handoff edit $w2
check 'an existing session keeps its windows' test "$(_lazyfleet_tmux list-windows -t "=app/feat-b:" | wc -l | tr -d ' ')" = $(( n + 1 ))

# --- awkward worktree paths
w3=$(mkwt feat/c "feat c's dir")
_lazyfleet_handoff edit $w3
check 'a path with a space and a quote works' retry 'tools_seen | gq -F "pwd=$w3"'

# --- tools that fail
w4=$(mkwt feat/d feat-d)
ATTACHED=()
out=$(EDITOR=quickeditor _lazyfleet_handoff edit $w4 2>&1); rc=$?
check 'an editor that ends at once is an error' eval 'test $rc = 1 && gq "ended right away" <<<$out'
check 'and nothing is attached' test "$#ATTACHED" = 0
check 'it leaves no window behind' eval '! winnames app/feat-d | gq "^edit$"'
out=$(EDITOR=no-such-editor _lazyfleet_handoff edit $w4 2>&1); rc=$?
check 'a missing editor is an error' eval 'test $rc = 1 && gq "not found" <<<$out'
check 'and makes no session' eval '! _lazyfleet_tmux has-session -t "=app/feat-d:" 2>/dev/null || ! winnames app/feat-d | gq "^edit$"'
out=$(_lazyfleet_handoff edit $SANDBOX/not-a-worktree 2>&1); rc=$?
check 'something that is not a worktree is an error' test $rc = 1
out=$(_lazyfleet_handoff bogus $w4 2>&1); rc=$?
check 'an unknown tool is an error' test $rc = 1

# --- the pull request in the browser
pr() {  # number state merged-at-or-empty branch url
  jq -n --argjson n $1 --arg st $2 --arg mg "$3" --arg ref "$4" --arg url "$5" \
    '{number:$n, state:$st, draft:false, merged_at:(if $mg=="" then null else $mg end), title:"t",
      html_url:$url, head:{ref:$ref, sha:"0000000000000000000000000000000000000001", repo:{full_name:"acme/widgets"}}}'
}
refresh() {
  rm -rf $TMPDIR/lazyfleet-*/pr 2>/dev/null
  _lazyfleet_pr_cachefile acme/widgets && _lazyfleet_pr_fetch acme/widgets $REPLY "$@" >/dev/null 2>&1
}
seen() { [[ -r $BROWSER_LOG ]] && cat $BROWSER_LOG }
opened() { rm -f $BROWSER_LOG; out=$(_lazyfleet_openpr "$1" 2>&1); rc=$?; err=$out }
export BROWSER=mybrowser
wp=$(mkwt feat/pr feat-pr)
wn=$(mkwt feat/nopr feat-nopr)
{
  pr 7 open '' feat/pr https://github.com/acme/widgets/pull/7
  pr 8 closed 2026-01-01T00:00:00Z feat/merged https://github.com/acme/widgets/pull/8
  pr 9 open '' feat/evil1 'https://evil.test/acme/widgets/pull/9'
  pr 10 open '' feat/evil2 'https://github.com/acme/widgets/pull/10; touch /tmp/pwned'
  pr 11 open '' feat/evil3 'file:///etc/passwd'
  pr 12 open '' feat/evil4 'https://github.com/acme/widgets/pull/12/../../../evil'
  pr 13 open '' feat/evil5 '-oProxyCommand=touch x'
  pr 14 open '' feat/evil6 'https://github.com.evil.test/a/b/pull/14'
} | jq -s . >$FIX/pulls.json
wm=$(mkwt feat/merged feat-merged)
we1=$(mkwt feat/evil1 evil1); we2=$(mkwt feat/evil2 evil2); we3=$(mkwt feat/evil3 evil3)
we4=$(mkwt feat/evil4 evil4); we5=$(mkwt feat/evil5 evil5); we6=$(mkwt feat/evil6 evil6)

opened $wp
check 'before any data exists it says to try again' eval 'test $rc = 1 && gq "no pull request data yet" <<<$err'
check 'and opens nothing' test ! -e $BROWSER_LOG
refresh feat/pr feat/nopr feat/merged feat/evil1 feat/evil2 feat/evil3 feat/evil4 feat/evil5 feat/evil6
opened $wp
check 'the pull request opens in the browser' eval 'test $rc = 0 && test "$(seen)" = https://github.com/acme/widgets/pull/7'
opened $wm
check 'a merged pull request opens too' eval 'test $rc = 0 && test "$(seen)" = https://github.com/acme/widgets/pull/8'
opened $wn
check 'a branch without a pull request says so' eval 'test $rc = 1 && gq "no pull request known for feat/nopr" <<<$err'
check 'and opens nothing then' test ! -e $BROWSER_LOG
for d in $we1 $we2 $we3 $we4 $we5 $we6; do
  opened $d
  check "a poisoned link is refused (${d:t})" eval 'test $rc = 1 && gq "not a GitHub pull request link" <<<$err && test ! -e $BROWSER_LOG'
done
check 'nothing was run from a link' not test -e /tmp/pwned
git -C $wn checkout -q --detach
opened $wn
check 'a detached worktree has no pull request' eval 'test $rc = 1 && gq "is not on a branch" <<<$err'
git -C $wn checkout -q feat/nopr
LAZYFLEET_PR_STATUS=off opened $wp
check 'pr_status=off: no pull requests' eval 'test $rc = 1 && gq "need gh, a GitHub origin, and pr_status on" <<<$err'
opened $SANDBOX
check 'something that is not a worktree is an error' test $rc = 1

BROWSER="mybrowser --new-window" opened $wp
check 'a BROWSER with arguments works' eval 'test "$(seen)" = $'"'"'--new-window\nhttps://github.com/acme/widgets/pull/7'"'"''
unset BROWSER
opened $wp
check 'without BROWSER, xdg-open is used' eval 'test $rc = 0 && test "$(seen)" = https://github.com/acme/widgets/pull/7'
out=$( ( unset 'commands[xdg-open]'; _lazyfleet_openpr $wp ) 2>&1); rc=$?
check 'with no browser at all it says so' eval 'test $rc = 1 && gq "no browser found" <<<$out'
export BROWSER=mybrowser

# --- the keys
FZF_LABEL=" Worktrees "
k() { FZF_KEY=$1 FZF_LIST_LABEL=$FZF_LABEL _lazyfleet_key ${2:-w} ${3-/some/path} }
check 'e on a worktree hands over to the editor' eval 'k e | gq "^become(printf .* edit {2})$"'
check 'g on a worktree hands over to lazygit' eval 'k g | gq "^become(printf .* lazygit {2})$"'
check 'o on a worktree opens its pull request' eval 'k o | gq "^execute(.* _ui_openpr {2})$"'
for key in e g o; do
  check "$key does nothing in the windows view" test -z "$(FZF_LIST_LABEL=' Windows ' FZF_KEY=$key _lazyfleet_key t '=a/b:1')"
  check "$key does nothing without a row" test -z "$(k $key w '')"
done
check 'paths stay out of the action text' eval 'for key in e g o; do FZF_KEY=$key FZF_LIST_LABEL=" Worktrees " _lazyfleet_key w "/x/PWNED"; done | { ! gq PWNED }'
check 'e, g and o are typed into the filter, not run, while it is shown' eval '[[ $_LAZYFLEET_LETTERS == *,e,* && $_LAZYFLEET_LETTERS == *,g,* && $_LAZYFLEET_LETTERS == *,o,* ]]'
check 'the footer names the keys' eval '[[ $_LAZYFLEET_FOOTER_WT == *"(e)ditor"* && $_LAZYFLEET_FOOTER_WT == *"(g) lazygit"* && $_LAZYFLEET_FOOTER_WT == *"(o)pen PR"* ]]'
check 'the windows footer is unchanged' eval '[[ $_LAZYFLEET_FOOTER_WIN != *lazygit* ]]'

# --- the TUI loop starts the tools
fn=${functions[_lazyfleet_ui]}
check 'the TUI loop knows the edit action' eval '[[ $fn == *"(edit|lazygit)"*"_lazyfleet_handoff"* ]]'
check 'and binds the keys' eval '[[ $fn == *"for k in / n d p e g o O r a c C R q"* ]]'

if (( fails )); then print -P "%F{red}$fails failed%f"; exit 1; fi
print -P "%F{green}all passed%f"
