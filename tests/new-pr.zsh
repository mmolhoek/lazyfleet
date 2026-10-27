#!/usr/bin/env -S zsh -f
# Tests for O: GitHub's "create pull request" page in the browser. The
# browser is a stub that records what it was asked to open; nothing is created.

ROOT=${0:A:h:h}
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg LAZYFLEET_WORKTREES=$SANDBOX/wt TMPDIR=$SANDBOX/tmp
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p $HOME $TMPDIR $SANDBOX/stub
unset TMUX LAZYFLEET_PR_STATUS BROWSER
source $ROOT/lazyfleet.zsh
trap 'rm -rf $SANDBOX' EXIT

fails=0
ok()   { print -P "%F{green}ok%f   $1" }
fail() { print -P "%F{red}FAIL%f $1"; (( fails++ )) }
check() { local d=$1; shift; if "$@"; then ok $d; else fail $d; fi }
gq() { grep "$@" >/dev/null 2>&1 }

STUB=$SANDBOX/stub
cat >$STUB/mybrowser <<'STUB'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a" >>"$BROWSER_LOG"; done
STUB
cp $STUB/mybrowser $STUB/xdg-open
chmod +x $STUB/*
path=($STUB $path); rehash
export BROWSER=mybrowser BROWSER_LOG=$SANDBOX/browser.log

ORIGIN=https://github.com/acme/widgets.git
git() { if [[ $* == *'remote get-url origin'* ]]; then print -r -- $ORIGIN; else command git "$@"; fi }

repo=$SANDBOX/app
git init -q -b main $repo && git -C $repo commit -q --allow-empty -m init
git -C $repo update-ref refs/remotes/origin/main HEAD
git -C $repo symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
# a worktree on branch $1, which is on origin when $2 is "pushed"
mkwt() {
  git -C $repo worktree add -q -b $1 "$SANDBOX/wt-${1//\//-}" 2>/dev/null
  [[ $2 == pushed ]] && git -C $repo update-ref "refs/remotes/origin/$1" $1
  print -r -- "$SANDBOX/wt-${1//\//-}"
}
seen() { [[ -r $BROWSER_LOG ]] && cat $BROWSER_LOG }
run() { rm -f $BROWSER_LOG; out=$(_lazyfleet_newpr "$@" 2>&1); rc=$? }

# --- the page that opens
w=$(mkwt feat/a pushed)
run $w
check 'opens the compare page of the branch' eval 'test $rc = 0 && test "$(seen)" = "https://github.com/acme/widgets/compare/feat/a?expand=1"'

# --- awkward branch names are encoded, not passed on
w2=$(mkwt 'feat/a&b#c' pushed)
run $w2
check 'characters with a meaning in a URL are encoded' eval 'test "$(seen)" = "https://github.com/acme/widgets/compare/feat/a%26b%23c?expand=1"'
w3=$(mkwt 'feat/é' pushed)
run $w3
check 'non-ASCII characters are encoded byte by byte' eval 'test "$(seen)" = "https://github.com/acme/widgets/compare/feat/%C3%A9?expand=1"'
w4=$(mkwt 'feat/x;touch${IFS}pwned' pushed)
run $w4
check 'shell syntax in a branch name stays inert' eval 'test "$(seen)" = "https://github.com/acme/widgets/compare/feat/x%3Btouch%24%7BIFS%7Dpwned?expand=1" && test ! -e pwned'
check 'the URL is a single argument' eval 'test "$(seen | wc -l | tr -d " ")" = 1'

# --- refusals
w5=$(mkwt feat/local)
run $w5
check 'a branch that is not on origin is refused' eval 'test $rc = 1 && gq "not on origin yet" <<<$out && gq "git push -u origin feat/local" <<<$out'
check 'and opens nothing' test ! -e $BROWSER_LOG
run $repo
check 'the default branch is refused' eval 'test $rc = 1 && gq "is the default branch" <<<$out && test ! -e $BROWSER_LOG'
git -C $w5 checkout -q --detach
run $w5
check 'a detached worktree is refused' eval 'test $rc = 1 && gq "is not on a branch" <<<$out'
run $SANDBOX
check 'something that is not a worktree is refused' test $rc = 1
ORIGIN=https://gitlab.com/acme/widgets.git run $w
check 'an origin that is not on GitHub is refused' eval 'test $rc = 1 && gq "needs a GitHub origin" <<<$out && test ! -e $BROWSER_LOG'
ORIGIN=git@github.com:acme/widgets.git run $w
check 'an ssh origin works' eval 'test $rc = 0 && gq "acme/widgets/compare/feat/a" <<<"$(seen)"'
unset BROWSER
out=$( ( : $commands[xdg-open]; unset "commands[xdg-open]"; _lazyfleet_newpr $w ) 2>&1); rc=$?
check 'with no browser at all it says so' eval 'test $rc = 1 && gq "no browser found" <<<$out'
export BROWSER=mybrowser

# --- the key
k() { FZF_KEY=$1 FZF_LIST_LABEL=" Worktrees " _lazyfleet_key ${2:-w} ${3-/some/path} }
check 'O opens the new pull request page' eval 'k O | gq "^execute(.* _ui_newpr {2})$"'
for key in O; do
  check "$key does nothing on a repo" test -z "$(FZF_LIST_LABEL=' Repos ' FZF_KEY=$key _lazyfleet_key r /x)"
  check "$key does nothing in the windows view" test -z "$(FZF_LIST_LABEL=' Windows ' FZF_KEY=$key _lazyfleet_key t '=a/b:1')"
  check "$key does nothing without a row" test -z "$(k $key w '')"
  check "$key keeps the path out of the action text" eval '! FZF_KEY=$key FZF_LIST_LABEL=" Worktrees " _lazyfleet_key w /x/PWNED | gq PWNED'
done
check 'd still deletes' eval 'k d | gq "_ui_rm {2}"'
check 'O is typed into the filter, not run, while it is shown' eval '[[ $_LAZYFLEET_LETTERS == *,O,* ]]'
check 'the footer names it' eval '[[ $_LAZYFLEET_FOOTER_WT == *"(O) new PR"* ]]'
check 'the keys are bound' eval '[[ "${functions[_lazyfleet_ui]}" == *"for k in / n d p e g o O r a c C R q"* ]]'
check 'the dispatcher reaches _ui_newpr' eval '[[ "${functions[_lazyfleet_main]}" == *"_*) _lazyfleet\$cmd"* ]] && (( $+functions[_lazyfleet_ui_newpr] ))'

if (( fails )); then print -P "%F{red}$fails failed%f"; exit 1; fi
print -P "%F{green}all passed%f"
