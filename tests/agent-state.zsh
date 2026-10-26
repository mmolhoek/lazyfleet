#!/usr/bin/env -S zsh -f
# Tests for agent state: the hook script, state resolution, marks,
# notifications and the hook installer.

ROOT=${0:A:h:h}
HOOK=$ROOT/bin/lazyfleet-hook
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg XDG_CACHE_HOME=$SANDBOX/cache TMPDIR=$SANDBOX/tmp
export TMUX_TMPDIR=$SANDBOX GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p $HOME $TMPDIR $SANDBOX/stub
unset TMUX TMUX_PANE LAZYFLEET_AGENT_DIR LAZYFLEET_AGENT_ICONS LAZYFLEET_AGENT_NOTIFY
export LAZYFLEET_TMUX="tmux -L lazyfleet-state-$$" SHELL=${commands[zsh]}
AGENTS=$XDG_CACHE_HOME/lazyfleet/agents
cleanup() { tmux -L lazyfleet-state-$$ kill-server 2>/dev/null; rm -rf $SANDBOX }
trap cleanup EXIT

fails=0
ok()   { print -P "%F{green}ok%f   $1" }
fail() { print -P "%F{red}FAIL%f $1"; (( fails++ )) }
check() { local d=$1; shift; if "$@"; then ok $d; else fail $d; fi }
skip() { print -P "%F{yellow}skip%f $1 ($2)" }
gq() { grep "$@" >/dev/null 2>&1 }
not() { ! "$@" }
retry() { local i; for i in {1..50}; do eval "$1" && return 0; sleep 0.1; done; return 1 }
plain() { sed 's/\x1b\[[0-9;]*m//g' }

# ============================================================ the hook script
# run it as an agent's hook would, inside a pane: $1 socket, $2 pane, then kind, state
hook() { local sock=$1 pane=$2; shift 2; TMUX=$sock,1234,0 TMUX_PANE=$pane sh $HOOK "$@" }
keyof() { print -rn -- "$1$2" | tr -c 'A-Za-z0-9' _ }
stateof() { local f=$AGENTS/$1.$(keyof $2 $3); [[ -r $f ]] && { read -r st ts <$f; print -r -- $st } }
S1=/tmp/tmux-1000/default
rm -rf $AGENTS

hook $S1 %1 claude working
check 'the hook records a state' test "$(stateof claude $S1 %1)" = working
check 'the record carries the time' gq -E '^working [0-9]{9,}$' $AGENTS/claude.$(keyof $S1 %1)
hook $S1 %1 claude waiting
check 'a new state replaces the old' test "$(stateof claude $S1 %1)" = waiting
hook $S1 %1 claude done;  check 'done is recorded' test "$(stateof claude $S1 %1)" = done
hook $S1 %1 claude idle;  check 'idle is recorded' test "$(stateof claude $S1 %1)" = idle
hook $S1 %1 claude clear
check 'clear removes the record' test ! -e $AGENTS/claude.$(keyof $S1 %1)
hook $S1 %1 claude clear
check 'clearing nothing is fine' true

hook $S1 %1 claude working; hook $S1 %2 claude done; hook $S1 %1 copilot waiting
hook /tmp/tmux-1000/other %1 claude idle
check 'panes have separate records' test "$(stateof claude $S1 %1)/$(stateof claude $S1 %2)" = working/done
check 'agents in one pane have separate records' test "$(stateof copilot $S1 %1)" = waiting
check 'tmux servers have separate records' test "$(stateof claude /tmp/tmux-1000/other %1)" = idle
check 'the record names are plain file names' test -z "$(ls $AGENTS | grep -v -E '^[a-z]+\.[A-Za-z0-9_]+$')"

rm -rf $AGENTS
env -u TMUX TMUX_PANE=%1 sh $HOOK claude working
check 'outside tmux the hook does nothing' test ! -e $AGENTS
env -u TMUX_PANE TMUX=$S1,1,0 sh $HOOK claude working
check 'without a pane the hook does nothing' test ! -e $AGENTS
hook $S1 %1 vim working;     check 'an unknown agent is ignored' test ! -e $AGENTS
hook $S1 %1 claude sleeping; check 'an unknown state is ignored' test ! -e $AGENTS
hook $S1 %1 claude;          check 'a missing state is ignored' test ! -e $AGENTS
hook $S1 %1;                 check 'missing arguments are ignored' test ! -e $AGENTS
hook $S1 %1 '../x' working;  check 'a path in the agent name is ignored' test ! -e $AGENTS
check 'the hook always exits 0' eval 'hook $S1 %1 claude working; test $? = 0 && hook $S1 %1 vim x; test $? = 0'
print x >$SANDBOX/notadir
check 'an unwritable record dir does not fail the agent' eval 'LAZYFLEET_AGENT_DIR=$SANDBOX/notadir/sub hook $S1 %1 claude working; test $? = 0'
rm -rf $AGENTS; hook $S1 %1 claude working
check 'it leaves no temporary files' test "$(ls -A $AGENTS | wc -l | tr -d ' ')" = 1

# repeating a state does not rewrite the record (this runs on every tool call)
rm -rf $AGENTS; hook $S1 %1 claude working; first=$(<$AGENTS/claude.$(keyof $S1 %1)); sleep 1.2
hook $S1 %1 claude working
check 'repeating a state keeps the record as it was' test "$(<$AGENTS/claude.$(keyof $S1 %1))" = "$first"
hook $S1 %1 claude done; sleep 0; hook $S1 %1 claude working
check 'a different state does update it' test "$(stateof claude $S1 %1)" = working
check 'LAZYFLEET_AGENT_DIR moves the records' eval 'LAZYFLEET_AGENT_DIR=$SANDBOX/elsewhere hook $S1 %9 claude idle; test -n "$(ls $SANDBOX/elsewhere)"'

# going to waiting or done asks lazyfleet to consider a notification, in the background
mkdir -p $SANDBOX/hookbin; cp $HOOK $SANDBOX/hookbin/lazyfleet-hook
cat >$SANDBOX/hookbin/lazyfleet <<'STUB'
#!/bin/sh
echo "$*" >>"$NOTIFY_LOG"
STUB
chmod +x $SANDBOX/hookbin/lazyfleet
export NOTIFY_LOG=$SANDBOX/notify.log
nhook() { local sock=$1 pane=$2; shift 2; TMUX=$sock,1,0 TMUX_PANE=$pane sh $SANDBOX/hookbin/lazyfleet-hook "$@" }
rm -rf $AGENTS $NOTIFY_LOG
nhook $S1 %1 claude working; nhook $S1 %1 claude idle; nhook $S1 %1 claude clear; sleep 0.3
check 'working, idle and clear send no notification request' test ! -e $NOTIFY_LOG
nhook $S1 %1 claude waiting
check 'waiting asks for a notification' retry 'gq -x "_agent_notify claude waiting" $NOTIFY_LOG'
nhook $S1 %1 copilot done
check 'done asks for a notification' retry 'gq -x "_agent_notify copilot done" $NOTIFY_LOG'
rm -f $NOTIFY_LOG; nhook $S1 %1 claude waiting; sleep 0.3
check 'the same state again asks nothing more' test ! -e $NOTIFY_LOG
check 'a hook without lazyfleet next to it still succeeds' eval 'mkdir -p $SANDBOX/lone; cp $HOOK $SANDBOX/lone/; TMUX=$S1,1,0 TMUX_PANE=%3 sh $SANDBOX/lone/lazyfleet-hook claude done; test $? = 0'

(( fails )) && { print -P "\n%F{red}$fails failed%f"; exit 1 }
print -P "\n%F{green}all passed%f"
