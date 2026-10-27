#!/usr/bin/env -S zsh -f
# Tests for agent state: the hook script, state resolution, marks,
# notifications and the hook installer.

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools git tmux
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
hook $SOCK %3 claude done
check 'a recorded done is kept' test "$(field beta$'\t'0 4)" = done
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
check 'the windows view shows a waiting Claude' eval 'print -r -- $rows | grep -E "alpha.* 0:shell" | gq "✻!"'
check 'the windows view shows a finished Copilot' eval 'print -r -- $rows | grep -E "alpha.* 1:agent" | gq "✦✓"'
rows=$(LAZYFLEET_AGENT_ICONS=off _lazyfleet_winrows | plain)
check 'no marks at all when the icons are off' not eval 'print -r -- $rows | gq -E "✻|✦|π"'


# ============================================================== seen and status
# alpha:0 (%1) is on screen, alpha:1 (%2) is not, beta:0 (%3) is in a detached session
rm -rf $AGENTS; : >$SCREEN
hook $SOCK %1 claude done
_lazyfleet_agents -d
check 'finished work on screen has been seen' test "$(stateof claude $SOCK %1)" = idle
check 'and is reported as idle' test "$(field alpha$'\t'0 4)" = idle
hook $SOCK %1 claude waiting
check 'waiting on screen stays waiting' test "$(field alpha$'\t'0 4)" = waiting
hook $SOCK %2 copilot done
check 'finished work off screen stays done' test "$(field alpha$'\t'1 4)" = done
check 'and is not marked seen' test "$(stateof copilot $SOCK %2)" = done
hook $SOCK %3 claude done
check 'finished work in a detached session stays done' test "$(field beta$'\t'0 4)" = done

rm -rf $AGENTS; : >$SCREEN
check 'status is empty with nothing to report' test -z "$(_lazyfleet_status)"
hook $SOCK %1 claude waiting; hook $SOCK %2 copilot done; hook $SOCK %3 claude waiting; hook $SOCK %4 omp working
check 'status names waiting sessions that are off screen' test "$(_lazyfleet_status -p)" = '! beta ✓ alpha '
hook $SOCK %2 copilot working
check 'status ignores working agents and agents on screen' test "$(_lazyfleet_status -p)" = '! beta '
hook $SOCK %3 claude idle
check 'status is empty again when nothing needs you' test -z "$(_lazyfleet_status -p)"
hook $SOCK %2 copilot done; hook $SOCK %3 claude done
check 'status lists each session once' test "$(_lazyfleet_status -p)" = '✓ alpha beta '
panes_out=${panes_out//alpha/al#pha}
hook $SOCK %2 copilot done
check 'a # in a session name is escaped for tmux' gq -F 'al##pha' <<<"$(_lazyfleet_status)"
check 'and left alone in plain output' gq -F 'al#pha' <<<"$(_lazyfleet_status -p)"
panes_out=${panes_out//al#pha/alpha}
check 'status carries tmux colours by default' gq -F '#[fg=green]' <<<"$(_lazyfleet_status)"
check 'status -p carries none' not gq -F '#[' <<<"$(_lazyfleet_status -p)"
check 'the status command works through the dispatcher' test "$(_lazyfleet_main status -p)" = "$(_lazyfleet_status -p)"

# ============================================================== notifications
# canned tmux: pane %2 is in alpha, not on screen; two clients, one per session
calls=$SANDBOX/tmux.calls; fakeinfo='alpha@@lf@@100'
_lazyfleet_tmux() {
  print -r -- "$*" >>$calls
  case $1 in
    (display-message) [[ $2 == -p ]] && print -r -- $fakeinfo ;;
    (list-clients) print -r -- $'/dev/pts/1@@lf@@alpha\n/dev/pts/2@@lf@@beta' ;;
  esac
  return 0
}
note() { rm -f $calls; TMUX_PANE=${3:-%2} _lazyfleet_agent_notify $1 $2 }
sent() { gq -F -- "$1" $calls }
note claude waiting
check 'a message goes to the client in another session' sent 'display-message -c /dev/pts/2 -d 4000 -- ✻ alpha needs you'
check 'but not to a client already in that session' not sent '-c /dev/pts/1'
check 'status bars are refreshed' sent 'refresh-client -S'
note copilot done
check 'done has its own message' sent '✦ alpha is done'
note omp waiting
check 'omp gets its own icon' sent 'π alpha needs you'
fakeinfo='alpha@@lf@@111'; note claude waiting
check 'nothing is shown when the pane is on screen' not sent 'display-message -c'
check 'the status bars are refreshed anyway' sent 'refresh-client -S'
fakeinfo='alpha@@lf@@011'; note claude done
check 'a detached session counts as not looked at' sent 'display-message -c'
fakeinfo='al#pha@@lf@@100'; note claude done
check 'a # in the message is escaped' sent 'al##pha is done'
fakeinfo='alpha@@lf@@100'
note claude working;  check 'working sends nothing' test ! -e $calls
note claude idle;     check 'idle sends nothing' test ! -e $calls
note vim done;        check 'an unknown agent sends nothing' test ! -e $calls
rm -f $calls; env -u TMUX_PANE sh -c 'true'; unset TMUX_PANE; _lazyfleet_agent_notify claude done
check 'without a pane nothing happens' test ! -e $calls
check 'agent_notify=off keeps the messages away' eval 'LAZYFLEET_AGENT_NOTIFY=off note claude done; ! sent display-message\ -c'
check 'but still refreshes the status bars' eval 'LAZYFLEET_AGENT_NOTIFY=off note claude done; sent refresh-client'
mkdir -p $XDG_CONFIG_HOME/lazyfleet; print 'agent_notify=off' >$XDG_CONFIG_HOME/lazyfleet/config
note claude done
check 'agent_notify=off in the config works too' not sent 'display-message -c'
rm -rf $XDG_CONFIG_HOME/lazyfleet
check 'it always succeeds' eval 'note claude done; test $? = 0'
_lazyfleet_tmux() { return 1 }
check 'and does so without a tmux server' eval '_lazyfleet_agent_notify claude done; test $? = 0'

# ======================================================= end to end, real tmux
unset -f _lazyfleet_tmux; source $ROOT/lazyfleet.zsh
export LAZYFLEET_TMUX="tmux -L lazyfleet-state-$$" LAZYFLEET_AGENT_DIR=$AGENTS
rm -f $SANDBOX/stub/ps; rehash; rm -rf $AGENTS; mkdir -p $AGENTS
_lazyfleet_tmux new-session -d -s keepalive
_lazyfleet_tmux new-session -d -s e2e "zsh -fc 'exec -a claude sleep 120'"
pane=$(_lazyfleet_tmux list-panes -t '=e2e' -F '#{pane_id}')
tsock=$(_lazyfleet_tmux display-message -p -t $pane '#{socket_path}')
real_hook() { TMUX=$tsock,1,0 TMUX_PANE=$pane sh $ROOT/bin/lazyfleet-hook "$@" }
check 'a running Claude is found with the real tmux' retry '_lazyfleet_agents -d; (( $#reply ))'
real_hook claude done
check 'the status segment shows a finished agent' retry '[[ "$(bin=$ROOT/bin/lazyfleet; $bin status -p)" == "✓ e2e " ]]'
real_hook claude waiting
check 'and a waiting one' retry '[[ "$($ROOT/bin/lazyfleet status -p)" == "! e2e " ]]'
e2e_marks() { local -A agtally; _lazyfleet_agent_tally; _lazyfleet_agent_marks_at e2e -p; print -r -- $REPLY }
check 'the session marks show the state too' test "$(e2e_marks)" = '✻!'
real_hook claude clear
check 'a cleared agent is no longer reported' retry '[[ -z "$($ROOT/bin/lazyfleet status -p)" ]]'
_lazyfleet_tmux kill-session -t '=e2e'
real_hook claude done
check 'a stopped agent leaves no report, and its record goes' retry '[[ -z "$($ROOT/bin/lazyfleet status -p)" && -z "$(ls -A $AGENTS)" ]]'

# ================================================================ hooks install
if (( $+commands[jq] )); then
CL=$SANDBOX/claude; export CLAUDE_CONFIG_DIR=$CL; SET=$CL/settings.json
LAZYFLEET_DIR=$ROOT
hq() { jq -r "$1" $SET }
quiet() { "$@" >/dev/null 2>&1 }
rm -rf $CL
quiet _lazyfleet_hooks install
check 'install creates the settings file' test -f $SET
check 'the file is valid JSON' quiet jq -e . $SET
check 'there is a hook for each of the six events' test "$(hq '.hooks | keys | join(",")')" = Notification,PostToolUse,SessionEnd,SessionStart,Stop,UserPromptSubmit
check 'a prompt means working' gq -E "lazyfleet-hook' claude working\$" <<<"$(hq '.hooks.UserPromptSubmit[0].hooks[0].command')"
check 'Stop means done' gq -E "claude done\$" <<<"$(hq '.hooks.Stop[0].hooks[0].command')"
check 'the end of a session clears' gq -E "claude clear\$" <<<"$(hq '.hooks.SessionEnd[0].hooks[0].command')"
check 'a permission prompt means waiting' gq -E "claude waiting\$" <<<"$(hq '.hooks.Notification[0].hooks[0].command')"
check 'only prompts that need you count as waiting' test "$(hq '.hooks.Notification[0].matcher')" = 'permission_prompt|elicitation_dialog'
check 'events without a matcher have none' test "$(hq '.hooks.Stop[0] | has("matcher")')" = false
check 'there is no backup when there was nothing to back up' test ! -e $SET.lazyfleet.bak
check 'status says installed' quiet _lazyfleet_hooks status
quiet _lazyfleet_hooks install
check 'installing twice does not duplicate' test "$(hq '[.hooks[][]] | length')" = 6

# the installed command really runs the hook script, even with spaces in the path
mkdir -p "$SANDBOX/with space/bin"; cp $HOOK "$SANDBOX/with space/bin/"
LAZYFLEET_DIR="$SANDBOX/with space"; rm -rf $CL; quiet _lazyfleet_hooks install; LAZYFLEET_DIR=$ROOT
rm -rf $AGENTS
cmd=$(hq '.hooks.Stop[0].hooks[0].command')
TMUX=$SOCK,1,0 TMUX_PANE=%7 sh -c "$cmd"
check 'the installed command records the state' test "$(stateof claude $SOCK %7)" = done

# merging into settings that exist
rm -rf $CL; mkdir -p $CL
cat >$SET <<'JSON'
{"model":"opus","permissions":{"allow":["Bash(ls)"]},
 "hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}],
          "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"check.sh"}]}]}}
JSON
orig=$(<$SET)
out=$(_lazyfleet_hooks install 2>&1)
check 'settings of the user stay' test "$(hq '.model + (.permissions.allow[0])')" = 'opusBash(ls)'
check 'hooks of the user stay, on the same event' test "$(hq '.hooks.Stop[0].hooks[0].command')" = 'echo mine'
check 'ours are added after theirs' gq 'lazyfleet-hook' <<<"$(hq '.hooks.Stop[1].hooks[0].command')"
check 'hooks on other events stay' test "$(hq '.hooks.PreToolUse[0].matcher')" = Bash
check 'the original is backed up' test "$(<$SET.lazyfleet.bak)" = "$orig"
check 'the backup is mentioned' gq 'Backed up' <<<$out
quiet _lazyfleet_hooks install
check 'a second install keeps the first backup' test "$(<$SET.lazyfleet.bak)" = "$orig"
check 'and still does not duplicate' test "$(hq '.hooks.Stop | length')" = 2
LAZYFLEET_DIR="$SANDBOX/with space"; quiet _lazyfleet_hooks install; LAZYFLEET_DIR=$ROOT
check 'installing from another place replaces our old entries' test "$(hq '[.hooks.Stop[].hooks[].command | select(contains("with space"))] | length')/$(hq '.hooks.Stop | length')" = 1/2

quiet _lazyfleet_hooks uninstall
check 'uninstall removes our hooks' test "$(hq '[.. | strings | select(contains("lazyfleet-hook"))] | length')" = 0
check 'uninstall keeps the hooks of the user' test "$(hq '.hooks.Stop[0].hooks[0].command + .hooks.PreToolUse[0].matcher')" = 'echo mineBash'
check 'uninstall drops events that are empty now' test "$(hq '.hooks | keys | join(",")')" = PreToolUse,Stop
check 'uninstall keeps other settings' test "$(hq '.model')" = opus
check 'status says not installed' not quiet _lazyfleet_hooks status
quiet _lazyfleet_hooks uninstall
check 'uninstalling twice is fine' true
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x/lazyfleet-hook claude done"}]}]},"a":1}' >$SET
quiet _lazyfleet_hooks uninstall
check 'uninstall drops an empty hooks object' test "$(hq 'has("hooks")')" = false
check 'and keeps the rest' test "$(hq '.a')" = 1

rm -rf $CL
out=$(_lazyfleet_hooks uninstall 2>&1)
check 'uninstall without a settings file does nothing' test ! -e $SET
echo '{ not json' >$CL.json 2>/dev/null; mkdir -p $CL; print -r -- '{ not json' >$SET
quiet _lazyfleet_hooks install
check 'invalid settings are refused' not quiet _lazyfleet_hooks install
check 'and left as they were' test "$(<$SET)" = '{ not json'
check 'with no backup made' test ! -e $SET.lazyfleet.bak
check 'status on invalid settings does not claim anything' not quiet _lazyfleet_hooks status
rm -rf $CL
check 'an unknown subcommand is an error' not quiet _lazyfleet_hooks frobnicate
check 'hooks is reachable through the dispatcher' gq 'not installed' <<<"$(_lazyfleet_main hooks status 2>&1)"
unset CLAUDE_CONFIG_DIR
HOME=$SANDBOX/home2 quiet _lazyfleet_hooks install
check 'without CLAUDE_CONFIG_DIR it uses ~/.claude' test -f $SANDBOX/home2/.claude/settings.json
LAZYFLEET_DIR=$SANDBOX/nowhere
check 'it refuses to install a hook script that is not there' not quiet _lazyfleet_hooks install
LAZYFLEET_DIR=$ROOT
else
  skip 'hooks install tests' 'jq is not installed'
fi
check 'without jq the command says what it needs' eval 'out=$(PATH=/nonexistent /bin/zsh -f -c "source $ROOT/lazyfleet.zsh; _lazyfleet_hooks install" 2>&1); [[ $out == *jq* ]]'

finish
