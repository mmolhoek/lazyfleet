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


# ======================================================= state of live agents
source $ROOT/lazyfleet.zsh
export LAZYFLEET_AGENT_DIR=$AGENTS
SCREEN=$SANDBOX/screen; : >$SCREEN
_lazyfleet_tmux() {
  case $1 in
    (list-panes) print -r -- $panes_out ;;
    (capture-pane) cat $SCREEN ;;
    (*) return 1 ;;
  esac
}
cat >$SANDBOX/stub/ps <<'STUB'
#!/bin/sh
cat "$PS_TABLE"
STUB
chmod +x $SANDBOX/stub/ps; export PS_TABLE=$SANDBOX/ps.table
path=($SANDBOX/stub $path); rehash
S='@@lf@@'; SOCK=/tmp/tmux-1000/default
# pane pid, session, window, pane id, socket, attached/window_active/pane_active
panes_out="100${S}alpha${S}0${S}%1${S}${SOCK}${S}111
200${S}alpha${S}1${S}%2${S}${SOCK}${S}100
300${S}beta${S}0${S}%3${S}${SOCK}${S}011
400${S}gamma${S}0${S}%4${S}${SOCK}${S}111"
cat >$PS_TABLE <<'TABLE'
  100     1 -zsh
  101   100 claude
  200     1 -zsh
  201   200 copilot
  300     1 -zsh
  301   300 claude
  400     1 -zsh
  401   400 omp
TABLE
rm -rf $AGENTS
detail() { _lazyfleet_agents -d; print -rl -- $reply }
nf() { local -a f; f=("${(@ps:\t:)1}"); print $#f }
field() { local line; local -a f; for line in ${(f)"$(detail)"}; do [[ $line == $1$'\t'* ]] && { f=("${(@ps:\t:)line}"); print -r -- $f[$2]; return } done }

_lazyfleet_agents -d
check 'with -d each entry has six fields' test "$(nf $reply[1])" = 6
_lazyfleet_agents
check 'without -d the entries keep their three fields' test "$(nf $reply[1])" = 3
check 'the pane id comes along' test "$(field alpha$'\t'0 5)" = %1
check 'a pane being looked at is visible' test "$(field alpha$'\t'0 6)" = 1
check 'a pane in a window nobody shows is not' test "$(field alpha$'\t'1 6)" = 0
check 'a pane in a detached session is not' test "$(field beta$'\t'0 6)" = 0

check 'no record, no state (not Claude)' test "$(field alpha$'\t'1 4)" = ''
hook $SOCK %2 copilot waiting
check 'a record gives the state' test "$(field alpha$'\t'1 4)" = waiting
hook $SOCK %2 copilot done
check 'the latest record wins' test "$(field alpha$'\t'1 4)" = done
hook $SOCK %2 claude working
check 'another agent kind in the pane is not mixed up' test "$(field alpha$'\t'1 4)" = done
hook $SOCK %4 omp working
check 'omp state is read the same way' test "$(field gamma$'\t'0 4)" = working
print -r -- 'bogus 1' >$AGENTS/omp.$(keyof $SOCK %4)
check 'a damaged record is no state' test "$(field gamma$'\t'0 4)" = ''
hook /tmp/tmux-1000/elsewhere %4 omp done; rm -f $AGENTS/omp.$(keyof $SOCK %4)
check 'a record of another tmux server is not read' test "$(field gamma$'\t'0 4)" = ''

# Claude Code: the screen decides about working
rm -rf $AGENTS; : >$SCREEN
check 'Claude, nothing recorded, idle screen: unknown' test "$(field alpha$'\t'0 4)" = ''
print -r -- '✻ Thinking… (12s · esc to interrupt)' >$SCREEN
check 'Claude, nothing recorded, busy screen: working' test "$(field alpha$'\t'0 4)" = working
hook $SOCK %1 claude working; : >$SCREEN
check 'Claude recorded as working, screen idle: it was interrupted' test "$(field alpha$'\t'0 4)" = idle
print -r -- 'ESC TO INTERRUPT' >$SCREEN
check 'the screen text is matched in any case' test "$(field alpha$'\t'0 4)" = working
hook $SOCK %1 claude waiting; : >$SCREEN
check 'a recorded waiting is kept' test "$(field alpha$'\t'0 4)" = waiting
hook $SOCK %1 claude done
check 'a recorded done is kept' test "$(field alpha$'\t'0 4)" = done
printf 'old line esc to interrupt\n%.0s' 1 >$SCREEN; for i in {1..20}; do print x >>$SCREEN; done
hook $SOCK %1 claude working
check 'only the bottom of the screen counts' test "$(field alpha$'\t'0 4)" = idle

# records of agents that have stopped
rm -rf $AGENTS; hook $SOCK %1 claude done; hook $SOCK %2 copilot done; hook $SOCK %9 claude done
hook /tmp/tmux-1000/elsewhere %1 claude done; hook ${SOCK}2 %1 claude done
_lazyfleet_agents -d
check 'a record of a running agent stays' test -e $AGENTS/claude.$(keyof $SOCK %1)
check 'a record of a pane that is gone is removed' test ! -e $AGENTS/claude.$(keyof $SOCK %9)
check 'records of another server stay' test -e $AGENTS/claude.$(keyof /tmp/tmux-1000/elsewhere %1)
check 'a server whose socket starts the same is left alone' test -e $AGENTS/claude.$(keyof ${SOCK}2 %1)
hook $SOCK %3 copilot done
_lazyfleet_agents -d
check 'a record for an agent that is not in the pane is removed' test ! -e $AGENTS/copilot.$(keyof $SOCK %3)
rm -rf $AGENTS; hook $SOCK %9 claude done; _lazyfleet_agents
check 'without -d nothing is removed' test -e $AGENTS/claude.$(keyof $SOCK %9)
rm -rf $AGENTS; _lazyfleet_agents -d
check 'a missing record dir is fine' true


# ======================================================= tally and marks
tallied() { local -A agtally; _lazyfleet_agent_tally $1; local k; for k in ${(ko)agtally}; do print -r -- "$k=$agtally[$k]"; done }
_lazyfleet_tmux() {
  case $1 in
    (list-panes) print -r -- $panes_out ;;
    (capture-pane) cat $SCREEN ;;
    (list-windows) print -r -- $windows_out ;;
    (*) return 1 ;;
  esac
}
rm -rf $AGENTS; : >$SCREEN
hook $SOCK %1 claude waiting; hook $SOCK %2 copilot done; hook $SOCK %4 omp working
t=$(tallied)
check 'the tally counts per session and kind' gq -x 'alpha:claude=1' <<<$t
check 'the tally counts the state too' gq -x 'alpha:claude:waiting=1' <<<$t
check 'every kind has its own state count' gq -x 'alpha:copilot:done=1' <<<$t
check 'an agent of unknown state has no state count' not gq 'beta:claude:' <<<$t
check 'the tally by window includes the window' gq -x 'alpha:1:copilot:done=1' <<<"$(tallied w)"
marks_for() { local -A agtally; _lazyfleet_agent_tally; _lazyfleet_agent_marks_at $1 -p; print -r -- $REPLY }
check 'a session shows its agents and states' test "$(marks_for alpha)" = '✻! ✦✓'
check 'a session with an agent in an unknown state shows only the icon' test "$(marks_for beta)" = '✻'
check 'a working agent shows …' test "$(marks_for gamma)" = 'π…'
check 'a session without agents shows nothing' test -z "$(marks_for nothere)"
# the windows view
windows_out=$'alpha\t0:shell\tzsh\t/tmp\t\nalpha\t1:agent\tnode\t/tmp\t'
rows=$(_lazyfleet_winrows | plain)
check 'the windows view shows a waiting Claude' eval 'print -r -- $rows | grep -E "alpha +0:shell" | gq "✻!"'
check 'the windows view shows a finished Copilot' eval 'print -r -- $rows | grep -E "alpha +1:agent" | gq "✦✓"'
rows=$(LAZYFLEET_AGENT_ICONS=off _lazyfleet_winrows | plain)
check 'no marks at all when the icons are off' not eval 'print -r -- $rows | gq -E "✻|✦|π"'

(( fails )) && { print -P "\n%F{red}$fails failed%f"; exit 1 }
print -P "\n%F{green}all passed%f"
