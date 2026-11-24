#!/usr/bin/env -S zsh -f
# Tests for the logs of what runs from a worktree (lib/logs.zsh): l in the
# TUI and lazyfleet logs (in less, following), and the latest lines in the
# Details pane. docker is a fake that logs what it is asked; less is the real
# one, driven in tmux, for what ctrl-c and q do.

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools git tmux less
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg LAZYFLEET_WORKTREES=$SANDBOX/wt TMPDIR=$SANDBOX/tmp
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p $HOME $TMPDIR
unset TMUX LAZYFLEET_TUI
export LAZYFLEET_UPDATE_CHECK=off LAZYFLEET_PR_STATUS=off
trap 'tmux_cleanup; rm -rf $SANDBOX' EXIT
source $ROOT/lazyfleet.zsh

T=$'\t'
repo=$SANDBOX/app
git init -q -b main $repo && git -C $repo commit -q --allow-empty -m init
git -C $repo worktree add -q -b a $LAZYFLEET_WORKTREES/app/a 2>/dev/null
wa=$LAZYFLEET_WORKTREES/app/a

# --- the fake docker. ps: the compose query (it filters on the compose
# label) prints $F/compose, the 🐳 query $F/all, the services of one project
# $F/services; logs print $F/logs (compose
# with --timestamps: $F/stamped); "logs --follow" keeps going, a line a tenth
# of a second, until it is stopped. Every call is logged in $F/log.
F=$SANDBOX/fake; mkdir -p $F $SANDBOX/bin
cat >$SANDBOX/bin/docker <<'EOF'
#!/bin/sh
F=$FAKE
printf '%s|%s\n' "$PWD" "$*" >>"$F/log"
case "$*" in
  'compose version') exit 0 ;;
  *com.docker.compose.project=*) cat "$F/services" 2>/dev/null ;;
  ps\ --filter*) cat "$F/compose" 2>/dev/null ;;
  ps*) cat "$F/all" 2>/dev/null ;;
  *--follow*) echo "$$" >"$F/pid"; i=0; while :; do echo "follow line $i"; i=$((i+1)); sleep 0.1; done ;;
  *--timestamps*) cat "$F/stamped" ;;
  *logs*) cat "$F/logs" ;;
esac
EOF
chmod +x $SANDBOX/bin/docker
export FAKE=$F PATH=$SANDBOX/bin:$PATH; rehash
fresh() { rm -f $F/*(N); }
running() {  # running <compose lines> -- <all lines>
  local -a c a; local x
  while (( $# )) && [[ $1 != -- ]]; do c+=($1); shift; done
  shift; a=("$@")
  print -rl -- $c >$F/compose; print -rl -- $a >$F/all
}
calls() { [[ -e $F/log ]] && grep -v '|ps \|compose version' $F/log }

# --- what runs from a worktree
fresh; running "$wa${T}app${T}app-api-1" "$wa${T}app${T}app-db-1" "$repo${T}main${T}m-1" -- \
  "$wa${T}app-api-1${T}Up${T}1" "$wa${T}app-db-1${T}Up${T}2" "$wa${T}devc${T}Up${T}3" "$repo${T}m-1${T}Up${T}4"
_lazyfleet_logs_targets $wa
assert_eq 'targets: its compose project, then its other containers' \
  "compose${T}app${T}${T}compose project app (2 containers)|container${T}devc${T}${T}container devc" "${(j:|:)reply}"
_lazyfleet_logs_targets $repo
assert_eq 'targets: per worktree' "compose${T}main${T}${T}compose project main (1 container)" "$reply"
fresh; _lazyfleet_logs_targets $wa
assert_eq 'targets: nothing running, none' 0 $#reply

# --- the commands
_lazyfleet_logs_cmd "compose${T}app${T}${T}x"
assert_eq 'cmd: a compose project, following its last lines' "docker compose -p app logs --follow --tail 200" "$reply"
_lazyfleet_logs_cmd "container${T}devc${T}${T}x"
assert_eq 'cmd: a container' "docker logs --follow --tail 200 devc" "$reply"
_lazyfleet_logs_cmd -n 12 "compose${T}app${T}${T}x"
assert_eq 'cmd: -n, only that many lines, not following' "docker compose -p app logs --tail 12" "$reply"

_lazyfleet_logs_cmd -n 12 "compose${T}app${T}api worker${T}x"
assert_eq 'cmd: with services named, only theirs' "docker compose -p app logs --tail 12 api worker" "$reply"

# --- logs_hide= in the project config
hide() { _lazyfleet_projconf $repo; mkdir -p ${REPLY:h}; print -r -- "$1" >$REPLY }
nohide() { _lazyfleet_projconf $repo; rm -f $REPLY $repo/.lazyfleet }
compose_ab() {
  running "$wa${T}app${T}app-api-1" "$wa${T}app${T}app-db-1" -- "$wa${T}app-api-1${T}Up${T}1" "$wa${T}app-db-1${T}Up${T}2" "$@"
  print -rl -- "api${T}app-api-1" "db${T}app-db-1" >$F/services
}
fresh; compose_ab; hide 'logs_hide=db'
_lazyfleet_logs_targets $wa
assert_eq 'hide: a service, by its name: the others are named, and the count says so' \
  "compose${T}app${T}api${T}compose project app (1 container, 1 hidden)" "$reply"
check 'hide: compose is asked which service each container is' gq '|ps --filter label=com.docker.compose.project=app ' $F/log
_lazyfleet_logs_cmd -n 5 $reply[1]
assert_eq 'hide: its logs are left out' "docker compose -p app logs --tail 5 api" "$reply"
hide 'logs_hide=app-db-*'
_lazyfleet_logs_targets $wa
assert_eq 'hide: a container, by a pattern of its name' "compose${T}app${T}api${T}compose project app (1 container, 1 hidden)" "$reply"
hide 'logs_hide=nothing-like-it'
_lazyfleet_logs_targets $wa
assert_eq 'hide: nothing matching: all of it, as without' "compose${T}app${T}${T}compose project app (2 containers)" "$reply"
fresh; compose_ab "$wa${T}devc${T}Up${T}3"; hide 'logs_hide=api db dev?'
_lazyfleet_logs_targets $wa
assert_eq 'hide: all of it hidden, compose project and container: nothing' 0 $#reply
out=$(_lazyfleet_logs $wa 2>&1); rc=$?
assert_eq 'hide: l then fails' 1 $rc
assert_contains 'hide: and says why' "is hidden by logs_hide= in its project config (c)" $out
_lazyfleet_containers_in $wa >/dev/null
out=$(_lazyfleet_preview w $wa 2>/dev/null)
check 'hide: the Details pane then shows the git details' eval '[[ $out == *"commits since main"* && $out != *"compose project"* ]]'
fresh; compose_ab; nohide; print 'logs_hide=db' >$repo/.lazyfleet
_lazyfleet_logs_targets $wa
assert_eq 'hide: from the repo'"'"'s .lazyfleet too' "compose${T}app${T}api${T}compose project app (1 container, 1 hidden)" "$reply"
fresh; compose_ab; nohide
_lazyfleet_logs_targets $wa
check 'hide: not set: compose is not asked about services' not gq 'compose.project=app ' $F/log
_lazyfleet_projconf $repo; rm -f $REPLY
EDITOR=true _lazyfleet_main config $repo >/dev/null 2>&1
check 'hide: a new project config shows how' gq '^# logs_hide=' $REPLY
rm -f $REPLY

# --- choosing
_lazyfleet_logs_choose "compose${T}app${T}x"
assert_eq 'choose: the only one' "compose${T}app${T}x" $REPLY
check 'choose: none fails' not _lazyfleet_logs_choose
check 'choose: several, off a terminal, fails' eval '! _lazyfleet_logs_choose a b </dev/null'

# --- lazyfleet logs
fresh; out=$(_lazyfleet_logs $wa 2>&1); rc=$?
assert_eq 'logs: nothing running fails' 1 $rc
assert_contains 'logs: and says so' "no containers run from $wa" $out
running "$wa${T}app${T}app-api-1" -- "$wa${T}app-api-1${T}Up${T}1" "$wa${T}devc${T}Up${T}3"
out=$(_lazyfleet_logs $wa </dev/null 2>&1); rc=$?
assert_eq 'logs: several, off a terminal, fails' 1 $rc
assert_contains 'logs: and names them' 'compose project app (1 container), container devc' $out
running "$wa${T}app${T}app-api-1" -- "$wa${T}app-api-1${T}Up${T}1"
out=$( (_lazyfleet_logs_show() { print -r -- "show: $*" }; _lazyfleet_logs $wa) 2>&1 )
assert_eq 'logs: one, shown' "show: docker compose -p app logs --follow --tail 200" "$out"
out=$( (cd $wa; _lazyfleet_logs_show() { print -r -- "show: $*" }; _lazyfleet_main logs) 2>&1 )
assert_eq 'logs: the command, in the worktree it is run in' "show: docker compose -p app logs --follow --tail 200" "$out"
print 'plain line' >$F/logs
out=$(_lazyfleet_logs_show docker logs --tail 5 x </dev/null)
assert_eq 'show: off a terminal, straight out' 'plain line' "$out"
check 'show: run from /, where no compose file is read' gq '^/|logs --tail 5 x$' $F/log

# --- in less, on a terminal: ctrl-c stops following, not docker; q stops it
use_tmux logs
_lazyfleet_tmux new-session -d -s l -x 80 -y 12 \
  "zsh -f -c 'source $ROOT/lazyfleet.zsh; export PATH=$SANDBOX/bin:\$PATH FAKE=$F TMPDIR=$TMPDIR; _lazyfleet_logs_show docker logs --follow x; print SHOWN-DONE; sleep 30'"
pane() { _lazyfleet_tmux capture-pane -p -t l }
alive() { [[ -s $F/pid ]] && kill -0 $(<$F/pid) 2>/dev/null }
check 'less: shows the logs, following them' retry '[[ $(pane) == *"follow line 1"* && $(pane) == *"Waiting for data"* ]]'
_lazyfleet_tmux send-keys -t l C-c
check 'less: ctrl-c stops following' retry '[[ $(pane) != *"Waiting for data"* ]]'
sleep 0.3
check 'less: and stays open' eval '[[ $(pane) != *SHOWN-DONE* ]]'
check 'less: docker goes on (F follows again)' alive
_lazyfleet_tmux send-keys -t l q
check 'less: q quits' retry '[[ $(pane) == *SHOWN-DONE* ]]'
check 'less: and docker is stopped' retry '! alive'
check 'less: its file is gone' eval '[[ -z $(print -l $TMPDIR/lazyfleet-*/logs.*(N)) ]]'
tmux_cleanup

# --- the latest lines, for the Details pane
printf '%s\n' l1 l2 l3 l4 >$F/logs
assert_eq 'latest: a container: its last lines' $'l3\nl4' "$(_lazyfleet_logs_latest 2 docker logs --tail 2 x)"
cat >$F/stamped <<'EOF'
worker-1  | 2026-11-24T10:14:06.095Z w6
worker-1  | 2026-11-24T10:14:08.096Z w8
api-1     | 2026-11-24T10:14:07.001Z a7
api-1     | 2026-11-24T10:14:09.003Z a9 | with a bar
EOF
assert_eq 'latest: compose: services merged by time, the times taken out' \
  $'api-1     | a7\nworker-1  | w8\napi-1     | a9 | with a bar' "$(_lazyfleet_logs_latest 3 docker compose -p app logs --tail 3)"
check 'latest: compose is asked for the times' gq 'logs --tail 3 --timestamps$' $F/log
assert_eq 'latest: fewer lines than asked for: all of them' 4 "$(_lazyfleet_logs_latest 50 docker compose -p app logs --tail 50 | wc -l | tr -d ' ')"

# --- the Details pane
fresh; running "$wa${T}app${T}app-api-1" "$wa${T}app${T}app-db-1" -- "$wa${T}app-api-1${T}Up${T}1" "$wa${T}app-db-1${T}Up${T}2" "$wa${T}devc${T}Up${T}3"
cp /dev/null $F/stamped; print 'api-1  | 2026-11-24T10:00:00.000Z hello from api' >$F/stamped
_lazyfleet_containers_in $wa >/dev/null    # (fills the cache the pane reads)
out=$(FZF_PREVIEW_LINES=30 _lazyfleet_preview w $wa 2>/dev/null)
assert_contains 'pane: its session first' "${wa/#$HOME/~}" $out
assert_contains 'pane: how many run, and that l shows all' '🐳 3 running' $out
assert_contains 'pane: what the logs are of' 'compose project app (2 containers)' $out
assert_contains 'pane: of several, which and that l picks' '(1 of 2: l picks)' $out
assert_contains 'pane: the latest lines' 'api-1  | hello from api' $out
check 'pane: no git details then' eval '[[ $out != *"commits since main"* ]]'
check 'pane: as many lines as fit under the rest' gq 'compose -p app logs --tail 2[0-9] --timestamps$' $F/log
fresh; _lazyfleet_containers_in $wa >/dev/null; running '' -- ''
out=$(_lazyfleet_preview w $wa 2>/dev/null)
check 'pane: nothing running: the git details' eval '[[ $out == *"commits since main"* && $out != *"running"* ]]'
running "$wa${T}app${T}app-api-1" -- "$wa${T}app-api-1${T}Up${T}1"; _lazyfleet_containers_in $wa >/dev/null
running '' -- ''
out=$(_lazyfleet_preview w $wa 2>/dev/null)
check 'pane: the 🐳 cache says some, but they stopped: the git details' eval '[[ $out == *"commits since main"* && $out != *"compose project"* ]]'

# with -f it keeps redrawing as they change, until it is stopped
fresh; running "$wa${T}app${T}x" -- "$wa${T}x${T}Up${T}1"; _lazyfleet_containers_in $wa >/dev/null
print 'x  | 2026-11-24T10:00:00.000Z first' >$F/stamped
_lazyfleet_preview -f w $wa >$SANDBOX/pane 2>/dev/null &
pv=$!
check 'pane -f: drawn' retry 'gq first $SANDBOX/pane'
print 'x  | 2026-11-24T10:00:01.000Z second' >>$F/stamped
check 'pane -f: drawn again when they change' retry 'gq second $SANDBOX/pane'
kill $pv; wait $pv 2>/dev/null

# --- the key, and the TUI acting on it
k() { FZF_COLUMNS=120 FZF_KEY=l FZF_LIST_LABEL=" $1 " _lazyfleet_key $2 $3 }
assert_eq 'key: l hands over to the TUI (no fzf around less: it would end it on ctrl-c)' \
  "become(printf '%s\\n' logs {2})" "$(k Worktrees w $wa)"
check 'key: l does nothing in the windows' eval '[[ -z $(k Windows t "=a:1") ]]'
check 'key: l is typed while finding' eval '[[ ,$_LAZYFLEET_LETTERS, == *,l,* ]]'
check 'key: the footer names it' eval '[[ $_LAZYFLEET_FOOTER_WT == *"(l)ogs"* ]]'
(
  _lazyfleet_logs() { print -r -- "logs $1"; return ${LOGS_RC:-0} }
  out=$(_lazyfleet_ui_act $'logs\n'$wa; print "rc=$? view=$reply[1] sel=$reply[2]")
  assert_eq 'act: shows them, then the list again on that row' "logs $wa"$'\n'"rc=2 view= sel=$wa" "$out"
  out=$(LOGS_RC=1 _lazyfleet_ui_act $'logs\n'$wa; print "rc=$?")
  assert_eq 'act: also when it failed (the footer says why)' "logs $wa"$'\n'"rc=2" "$out"
)

finish
