#!/usr/bin/env -S zsh -f
# Tests for docker compose up and down per worktree (lib/compose.zsh): x in
# the TUI, lazyfleet compose. The unit tests use a fake docker that logs what
# it is asked; the last block runs real containers when a Docker daemon is
# there (an image made from this machine's own sleep: no registry needed).

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools git
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg LAZYFLEET_WORKTREES=$SANDBOX/wt TMPDIR=$SANDBOX/tmp
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p $HOME $TMPDIR
unset TMUX LAZYFLEET_TUI
export LAZYFLEET_UPDATE_CHECK=off
REAL_PATH=$PATH
REAL_DOCKER=${commands[docker]}
trap 'real_cleanup; rm -rf $SANDBOX' EXIT
real_cleanup() { :; }
source $ROOT/lazyfleet.zsh

T=$'\t'
# a repo "app" with worktrees a and b, each with a compose file
repo=$SANDBOX/app
git init -q -b main $repo && git -C $repo commit -q --allow-empty -m init
for w in a b; do git -C $repo worktree add -q -b $w $LAZYFLEET_WORKTREES/app/$w 2>/dev/null; done
wa=$LAZYFLEET_WORKTREES/app/a wb=$LAZYFLEET_WORKTREES/app/b
print 'services: {}' >$wa/compose.yaml; print 'services: {}' >$wb/compose.yaml

# --- the fake docker: logs "dir|args"; docker ps prints $SANDBOX/ps
mkdir -p $SANDBOX/bin
cat >$SANDBOX/bin/docker <<'EOF'
#!/bin/sh
printf '%s|%s\n' "$PWD" "$*" >>"$DOCKER_LOG"
case "$1 $2" in
  'compose version') exit "${NO_PLUGIN:-0}" ;;
  ps*) cat "$DOCKER_PS" 2>/dev/null ;;
  'compose up') exit "${UP_RC:-0}" ;;
  'compose -p') exit "${DOWN_RC:-0}" ;;
esac
EOF
chmod +x $SANDBOX/bin/docker
export DOCKER_LOG=$SANDBOX/log DOCKER_PS=$SANDBOX/ps
export PATH=$SANDBOX/bin:$REAL_PATH; rehash
ps_() { print -rl -- "$@" >$DOCKER_PS }
log() { [[ -e $DOCKER_LOG ]] && grep -v '|ps \|compose version' $DOCKER_LOG }   # what it was told to do
fresh() { rm -f $DOCKER_LOG $DOCKER_PS $HOME/.lazyfleet_history }

# --- the compose command
_lazyfleet_compose_cmd; assert_eq 'cmd: docker'"'"'s plugin' 'docker compose' "$reply"
( export NO_PLUGIN=1
  _lazyfleet_compose_cmd 2>/dev/null; assert_eq 'cmd: no plugin, no docker-compose: none' '' "$reply"
  print '#!/bin/sh' >$SANDBOX/bin/docker-compose; chmod +x $SANDBOX/bin/docker-compose; rehash
  _lazyfleet_compose_cmd; assert_eq 'cmd: else the old docker-compose' docker-compose "$reply"
  rm $SANDBOX/bin/docker-compose )
out=$( PATH=/nonexistent; _lazyfleet_compose_cmd 2>&1 ); rc=$?
assert_eq 'cmd: no docker at all, fails' 1 $rc
assert_contains 'cmd: and says so' 'docker compose is not installed' $out

# --- the compose file
d=$SANDBOX/files; mkdir -p $d
check 'file: none' not _lazyfleet_compose_file $d
for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
  touch $d/$f; check "file: $f" _lazyfleet_compose_file $d; rm $d/$f
done
print 'COMPOSE_FILE=ops/dev.yml' >$d/.env
check 'file: one named in .env' _lazyfleet_compose_file $d
print 'OTHER=1' >$d/.env
check 'file: an .env without one is not' not _lazyfleet_compose_file $d

# --- what runs
fresh; ps_ "$wa${T}app${T}app-db-1" "$wa${T}app${T}app-web-1" "${T}stray${T}x" "$wb${T}b${T}b-db-1" 'garbage'
_lazyfleet_compose_running
assert_eq 'running: the well-formed lines' 3 $#reply
check 'running: asks only for compose containers' gq 'ps --filter label=com.docker.compose.project ' $DOCKER_LOG
_lazyfleet_compose_projects $wa $reply
assert_eq 'projects: each once' app "$reply"
_lazyfleet_compose_running; _lazyfleet_compose_projects $wb $reply
assert_eq 'projects: per worktree' b "$reply"
ln -s $wa $SANDBOX/link
_lazyfleet_compose_running; _lazyfleet_compose_projects $SANDBOX/link $reply
assert_eq 'projects: a path through a symlink is the same dir' app "$reply"
_lazyfleet_compose_running; _lazyfleet_compose_projects $SANDBOX/files $reply
assert_eq 'projects: none from elsewhere' 0 $#reply

# what runs from the repo's other worktrees
fresh; ps_ "$wa${T}shared${T}s-db-1" "$wa${T}shared${T}s-web-1" "$SANDBOX/elsewhere${T}other${T}o-1" "$wb${T}shared${T}s-db-1"
_lazyfleet_compose_others $wb
assert_eq 'others: the other worktree of the repo, with a count' "$wa${T}shared${T}2" "$reply"
_lazyfleet_compose_others $repo
assert_eq 'others: from the main worktree, both of them' 2 $#reply
ps_ "$wb${T}b${T}b-1"
_lazyfleet_compose_others $wb
assert_eq 'others: only its own running, none' 0 $#reply
_lazyfleet_compose_others $SANDBOX/files
assert_eq 'others: not in a repo, none' 0 $#reply

# --- up
fresh
out=$(_lazyfleet_compose_up $SANDBOX/files 2>&1); rc=$?
assert_eq 'up: no compose file fails' 1 $rc
assert_contains 'up: and says where' "no compose file in $SANDBOX/files" $out
fresh; out=$(_lazyfleet_compose_up $wa 2>&1); rc=$?
assert_eq 'up: succeeds' 0 $rc
assert_eq 'up: compose up -d, in the worktree' "$wa|compose up -d" "$(log)"
check 'up: nothing in the history outside the TUI' test ! -e $HOME/.lazyfleet_history
fresh; LAZYFLEET_TUI=x _lazyfleet_compose_up $wa >/dev/null 2>&1
check 'up: in the TUI, noted in the history' gq "compose up in $wa\$" $HOME/.lazyfleet_history
fresh; out=$(UP_RC=1 _lazyfleet_compose_up $wa 2>&1); rc=$?
assert_eq 'up: compose failing fails' 1 $rc
assert_contains 'up: and says so' "compose up failed in $wa" $out

# others running: named; off a terminal left alone, asked on one
fresh; ps_ "$wa${T}shared${T}s-db-1"
out=$(_lazyfleet_compose_up $wb </dev/null 2>&1); rc=$?
assert_eq 'up: others running, off a terminal, still up' 0 $rc
assert_contains 'up: names what runs elsewhere' "$wa: project shared, 1 container(s)" $out
assert_eq 'up: and leaves it alone' "$wb|compose up -d" "$(log)"
fresh; ps_ "$wa${T}shared${T}s-db-1" "$repo${T}main${T}m-1"
out=$( (_lazyfleet_compose_askstop() { return 0 }; _lazyfleet_compose_up $wb) 2>&1 ); rc=$?
# (in the order of the repo's worktrees: the main one first)
assert_eq 'up: asked, yes: stops them there first, by project, then up' "/|compose -p main down"$'\n'"/|compose -p shared down"$'\n'"$wb|compose up -d" "$(log)"
fresh; ps_ "$wa${T}shared${T}s-db-1"
( _lazyfleet_compose_askstop() { return 1 }; _lazyfleet_compose_up $wb ) >/dev/null 2>&1
assert_eq 'up: asked, no: only up' "$wb|compose up -d" "$(log)"
fresh; ps_ "$wa${T}shared${T}s-db-1"
out=$( (export DOWN_RC=1; _lazyfleet_compose_askstop() { return 0 }; _lazyfleet_compose_up $wb) 2>&1 ); rc=$?
assert_eq 'up: stopping fails: not up' "/|compose -p shared down" "$(log)"
assert_eq 'up: and fails' 1 $rc

# --- down
fresh; out=$(_lazyfleet_compose_down $wa 2>&1); rc=$?
assert_eq 'down: nothing running fails' 1 $rc
assert_contains 'down: and says so' "no compose containers run from $wa" $out
fresh; ps_ "$wa${T}one${T}x" "$wa${T}two${T}y" "$wa${T}one${T}z" "$wb${T}three${T}w"
_lazyfleet_compose_down $wa >/dev/null 2>&1
assert_eq 'down: each of its projects once, by name, from /' "/|compose -p one down"$'\n'"/|compose -p two down" "$(log)"
fresh; ps_ "$wa${T}one${T}x"
LAZYFLEET_TUI=x _lazyfleet_compose_down $wa >/dev/null 2>&1
check 'down: in the TUI, noted' gq "compose down in $wa\$" $HOME/.lazyfleet_history
fresh; ps_ "$wa${T}one${T}x"
out=$(DOWN_RC=1 _lazyfleet_compose_down $wa 2>&1); rc=$?
assert_eq 'down: compose failing fails' 1 $rc
assert_contains 'down: and says so' "compose down failed in $wa" $out

# --- compose's own output: in the TUI only when it fails
say() { print -r -- "progress line"; return ${1:-0} }
out=$(_lazyfleet_compose_run 'compose up in x' say 2>&1)
assert_eq 'output: outside the TUI, as compose prints it' 'progress line' "$out"
out=$(LAZYFLEET_TUI=x _lazyfleet_compose_run 'compose up in x' say 2>&1); rc=$?
assert_eq 'output: in the TUI, a line for it, wiped when done' $'compose up in x…\r\e[K' "$out"
assert_eq 'output: and it succeeds' 0 $rc
out=$(LAZYFLEET_TUI=x _lazyfleet_compose_run 'compose up in x' say 3 2>&1); rc=$?
assert_eq 'output: in the TUI, shown when it fails' $'compose up in x…\r\e[Kprogress line' "$out"
assert_eq 'output: with its status' 3 $rc

# --- toggle, the command, the key
fresh; ps_ "$wa${T}one${T}x"
_lazyfleet_compose_toggle $wa >/dev/null 2>&1
assert_eq 'toggle: running: down' "/|compose -p one down" "$(log)"
fresh; _lazyfleet_compose_toggle $wa >/dev/null 2>&1
assert_eq 'toggle: not running: up' "$wa|compose up -d" "$(log)"
fresh; ( cd $wb && _lazyfleet_main compose up ) >/dev/null 2>&1
assert_eq 'command: compose up in the worktree it is run in' "$wb|compose up -d" "$(log)"
fresh; _lazyfleet_main compose toggle $wa >/dev/null 2>&1
assert_eq 'command: compose toggle <worktree>' "$wa|compose up -d" "$(log)"
out=$(_lazyfleet_main compose sideways $wa 2>&1); rc=$?
check 'command: anything else is refused with the usage' eval '(( rc == 1 )) && [[ $out == *"usage: lazyfleet compose up|down|toggle"* ]]'
out=$( (_lazyfleet_pause() { print paused }; UP_RC=1 _lazyfleet_ui_compose $wa) 2>/dev/null )
assert_eq 'tui: a failure waits for a key' paused "$(print -r -- $out | tail -1)"
out=$( (_lazyfleet_pause() { print paused }; _lazyfleet_ui_compose $wa) 2>/dev/null )
check 'tui: success does not' eval '[[ $out != *paused* ]]'
k() { FZF_COLUMNS=120 FZF_KEY=x FZF_LIST_LABEL=" $1 " _lazyfleet_key $2 $3 }
check 'key: x toggles, then reloads and refreshes the footer' eval '[[ $(k Worktrees w $wa) == "execute("*" _ui_compose {2})+"*"reload("*"+transform("*" _ui_refresh)" ]]'
check 'key: x does nothing in the windows' eval '[[ -z $(k Windows t "=a:1") ]]'
check 'key: x is typed while finding' eval '[[ ,$_LAZYFLEET_LETTERS, == *,x,* ]]'
check 'key: the footer names it' eval '[[ $_LAZYFLEET_FOOTER_WT == *"(x) compose up/down"* ]]'

# --- real containers, when there is a Docker daemon
export PATH=$REAL_PATH; rehash
if [[ -z $REAL_DOCKER ]] || ! docker info >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  skip 'real: no Docker daemon or compose plugin'
  finish
fi
img=lazyfleet-test-sleep:1
real_cleanup() {
  docker compose -p lftestshared down >/dev/null 2>&1
  docker image rm -f $img >/dev/null 2>&1
}
# the image: this machine's sleep and the libraries it needs
mkdir -p $SANDBOX/img
for f in ${commands[sleep]:A} ${(f)"$(ldd ${commands[sleep]:A} 2>/dev/null | grep -o '/[^ ]*')"}; do
  mkdir -p $SANDBOX/img${f:h} && cp -L $f $SANDBOX/img$f
done
tar -C $SANDBOX/img -c . | docker import -c "CMD [\"${commands[sleep]:A}\",\"600\"]" - $img >/dev/null 2>&1
if ! docker image inspect $img >/dev/null 2>&1; then
  skip 'real: could not make a test image'
  finish
fi
# both worktrees name the same project, as a compose file with name: does
for w in $wa $wb; do printf 'name: lftestshared\nservices:\n  app:\n    image: %s\n' $img >$w/compose.yaml; done
running_from() { _lazyfleet_compose_running; _lazyfleet_compose_projects $1 $reply; [[ $reply == lftestshared ]] }

_lazyfleet_compose_up $wa >/dev/null 2>&1
check 'real: up runs it from the worktree' running_from $wa
_lazyfleet_containers_in $wa
assert_eq 'real: and the 🐳 mark counts it' 1 $#reply
out=$(_lazyfleet_compose_up $wb </dev/null 2>&1)
assert_contains 'real: up in the other worktree names the clash' "$wa: project lftestshared, 1 container(s)" $out
check 'real: and, left alone, compose leaves it running from the first' running_from $wa
( _lazyfleet_compose_askstop() { return 0 }; _lazyfleet_compose_up $wb ) >/dev/null 2>&1
check 'real: stopped there first, it runs from the second' running_from $wb
check 'real: not from the first any more' not running_from $wa
_lazyfleet_compose_toggle $wb >/dev/null 2>&1
check 'real: toggled, it is down' not running_from $wb
_lazyfleet_compose_running
assert_eq 'real: nothing of it left' 0 ${#${(M)reply:#*${T}lftestshared${T}*}}

finish
