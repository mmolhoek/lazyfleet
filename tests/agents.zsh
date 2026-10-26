#!/usr/bin/env -S zsh -f
# Tests for the Claude Code / Copilot CLI icons.

ROOT=${0:A:h:h}
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg LAZYFLEET_WORKTREES=$SANDBOX/wt TMPDIR=$SANDBOX/tmp
export TMUX_TMPDIR=$SANDBOX GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p $HOME $TMPDIR $SANDBOX/stub
unset TMUX LAZYFLEET_AGENT_ICONS
export LAZYFLEET_TMUX="tmux -L lazyfleet-agents-$$" SHELL=${commands[zsh]}
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
retry() { local i; for i in {1..50}; do eval "$1" && return 0; sleep 0.1; done; return 1 }
plain() { sed 's/\x1b\[[0-9;]*m//g' }

# --- which command lines are agents
kind_is() { _lazyfleet_agent_kind "$2"; [[ $REPLY == $1 ]] }
for cl in 'claude' 'claude --resume' '/usr/local/bin/claude --dangerously-skip-permissions' \
          '/home/u/.local/share/claude/versions/2.0.14 --foo' \
          'node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js' \
          'node --no-warnings /home/u/.nvm/versions/node/v22/bin/claude' \
          'bun /opt/claude-code/cli.js'; do
  check "Claude Code: $cl" kind_is claude $cl
done
for cl in 'copilot' '/usr/local/bin/copilot --banner' \
          'node /usr/lib/node_modules/@github/copilot/index.js' \
          'node --enable-source-maps /home/u/.nvm/versions/node/v22/bin/copilot' \
          'gh copilot suggest'; do
  check "Copilot CLI: $cl" kind_is copilot $cl
done
for cl in 'zsh' '-zsh' '/bin/bash -l' 'vim claude.md' 'grep claude notes.txt' 'cat /home/u/claude' \
          'ssh claude@host' 'less copilot' 'node server.js' 'node /srv/app/bin/copilot-proxy.js' \
          'gh pr list' 'claude-desktop' 'Claude' '/Applications/Claude.app/Contents/MacOS/Claude' \
          'sleep 60' '/usr/bin/2.0.14' 'tmux new-session -s claude' '' ; do
  check "not an agent: ${cl:-(empty)}" not _lazyfleet_agent_kind "$cl"
done

# --- the process tree: tmux and ps are stubs with canned output
panes_out=''
_lazyfleet_tmux() {
  case $1 in
    (list-panes) print -r -- $panes_out ;;
    (list-windows) print -r -- $windows_out ;;
    (list-sessions) print -r -- $sessions_out ;;
    (*) return 1 ;;
  esac
}
cat >$SANDBOX/stub/ps <<'STUB'
#!/bin/sh
cat "$PS_TABLE"
STUB
chmod +x $SANDBOX/stub/ps
export PS_TABLE=$SANDBOX/ps.table
path=($SANDBOX/stub $path); rehash
S='@@lf@@'
panes_out="100${S}alpha${S}0
200${S}alpha${S}1
300${S}beta${S}0
400${S}gamma${S}2
700${S}delta${S}3
701${S}delta${S}3"
cat >$PS_TABLE <<'TABLE'
    1     0 /sbin/init
  100     1 -zsh
  101   100 claude --resume
  102   101 node /x/node_modules/@anthropic-ai/claude-code/cli.js
  200     1 -zsh
  201   200 npm exec
  202   201 node /usr/lib/node_modules/@github/copilot/index.js
  300     1 -zsh
  301   300 vim claude.md
  400     1 claude
  500     1 claude
  600   601 claude
  601   600 sleep 1
  700     1 -zsh
  701     1 -zsh
  710   700 claude
  711   701 claude
TABLE
_lazyfleet_agents
expected=($'alpha\t0\tclaude' $'alpha\t1\tcopilot' $'delta\t3\tclaude' $'delta\t3\tclaude' $'gamma\t2\tclaude')
check 'finds every agent, once per pane and kind' test "${(j:,:)reply}" = "${(j:,:)expected}"
has() { [[ -n ${reply[(r)$1]} ]] }
count() { local -a m; m=(${(M)reply:#$1}); print $#m }
check 'an agent and its child in one pane count once' test "$(count alpha$'\t'0$'\t'claude)" = 1
check 'an agent buried under other processes is found' has alpha$'\t'1$'\t'copilot
check 'an agent that is the pane process itself is found' has gamma$'\t'2$'\t'claude
check 'two panes in one window count twice' test "$(count delta$'\t'3$'\t'claude)" = 2
check 'a file named like an agent is not one' test -z "${(M)reply:#beta*}"
check 'agents outside any pane, and a process loop, are ignored' test $#reply = 5

panes_out=''
_lazyfleet_agents
check 'no panes, no agents' test $#reply = 0
_lazyfleet_tmux() { return 1 }
_lazyfleet_agents
check 'no tmux server, no agents' test $#reply = 0

# --- the marks
_lazyfleet_agent_marks 1 0 p; check 'one Claude' test "$REPLY" = '✻'
_lazyfleet_agent_marks 0 1 p; check 'one Copilot' test "$REPLY" = '✦'
_lazyfleet_agent_marks 2 0 p; check 'two Claudes show a count' test "$REPLY" = '✻2'
_lazyfleet_agent_marks 1 3 p; check 'both, with a count where above one' test "$REPLY" = '✻ ✦3'
_lazyfleet_agent_marks 0 2 p; check 'only Copilot, with a count' test "$REPLY" = '✦2'
_lazyfleet_agent_marks 0 0 p; check 'none shows nothing' test -z "$REPLY"
_lazyfleet_agent_marks '' '' p; check 'empty counts show nothing' test -z "$REPLY"
_lazyfleet_agent_marks 1 1; check 'colours by default' eval 'gq $'"'"'\e'"'"' <<<$REPLY'
_lazyfleet_agent_marks 1 1; check 'the colours leave the marks readable' test "$(plain <<<$REPLY)" = '✻ ✦'

# --- the setting
unset LAZYFLEET_AGENT_ICONS; rm -rf $XDG_CONFIG_HOME/lazyfleet
check 'on by default' _lazyfleet_agent_icons_on
check 'off by env var' not env LAZYFLEET_AGENT_ICONS=off zsh -f -c "source $ROOT/lazyfleet.zsh; _lazyfleet_agent_icons_on"
mkdir -p $XDG_CONFIG_HOME/lazyfleet; print 'agent_icons=off' >$XDG_CONFIG_HOME/lazyfleet/config
check 'off in the config' not _lazyfleet_agent_icons_on
check 'the env var wins over the config' env LAZYFLEET_AGENT_ICONS=on zsh -f -c "XDG_CONFIG_HOME=$XDG_CONFIG_HOME; source $ROOT/lazyfleet.zsh; _lazyfleet_agent_icons_on"
rm -rf $XDG_CONFIG_HOME/lazyfleet

# --- the windows view, from canned tmux output (real tabs: no tmux 3.4 mangling)
windows_out=$'alpha\t0:shell\tzsh\t/tmp\t\nalpha\t1:agent\tnode\t/tmp\t●\nbeta\t0:vim\tvim\t/tmp\t'
panes_out="100${S}alpha${S}0
200${S}alpha${S}1
300${S}beta${S}0"
_lazyfleet_tmux() {
  case $1 in
    (list-panes) print -r -- $panes_out ;;
    (list-windows) print -r -- $windows_out ;;
    (*) return 1 ;;
  esac
}
rows=$(_lazyfleet_winrows | plain)
row() { print -r -- $rows | grep -E "$1" }
check 'a window with Claude gets the Claude mark' eval 'row "alpha +0:shell" | gq "✻"'
check 'a window with Copilot gets the Copilot mark' eval 'row "alpha +1:agent" | gq "✦"'
check 'a window without agents gets no mark' not eval 'row "beta +0:vim" | gq -E "✻|✦"'
check 'the live marker is kept next to the mark' eval 'row "alpha +1:agent" | gq "● ✦"'
rows=$(LAZYFLEET_AGENT_ICONS=off _lazyfleet_winrows | plain)
check 'no marks when the icons are off' not eval 'print -r -- $rows | gq -E "✻|✦"'
unset -f _lazyfleet_tmux; source $ROOT/lazyfleet.zsh
export LAZYFLEET_TMUX="tmux -L lazyfleet-agents-$$"
rm -f $SANDBOX/stub/ps; rehash

# --- end to end: real tmux, real processes called claude and copilot
repo=$SANDBOX/src/app
mkdir -p $repo && cd $repo && git init -q -b main && print x >f && git add -A && git commit -qm init
lazyfleet add >/dev/null
_lazyfleet_tmux new-session -d -s keepalive
rows=$(_lazyfleet_rows -p)
check 'a worktree without agents has no mark' eval '! gq -E "✻|✦" <<<$rows'
_lazyfleet_tmux new-session -d -s app "zsh -fc 'exec -a claude sleep 120'"
check 'a running Claude shows on its worktree' retry '_lazyfleet_rows -p | gq "✻"'
check 'the mark sits on the worktree row, after the live marker' eval '_lazyfleet_rows -p | grep "^w"$'"'"'\t'"'"'"$repo" | gq "● .*✻"'
check 'the same on the full rows' eval '_lazyfleet_rows | plain | grep "^w"$'"'"'\t'"'"'"$repo" | gq "✻"'
_lazyfleet_tmux new-window -d -t '=app:' "zsh -fc 'exec -a copilot sleep 120'"
check 'a running Copilot is added' retry '_lazyfleet_rows -p | gq "✻ ✦"'
check 'icons off hides them' not eval 'LAZYFLEET_AGENT_ICONS=off _lazyfleet_rows -p | gq -E "✻|✦"'
_lazyfleet_tmux kill-session -t '=app'
check 'a stopped agent shows no more' retry '! _lazyfleet_rows -p | gq -E "✻|✦"'
_lazyfleet_tmux new-session -d -s app "zsh -fc 'exec -a copilot sleep 120'"
check 'a worktree with only Copilot shows the Copilot mark' retry '_lazyfleet_rows -p | gq "✦"'
check 'a worktree with only Copilot does not show the Claude mark' not eval '_lazyfleet_rows -p | gq "✻"'
_lazyfleet_tmux kill-session -t '=app'
if [[ $(_lazyfleet_tmux list-windows -a -F $'a\tb' 2>/dev/null | head -1) == $'a\tb' ]]; then
  _lazyfleet_tmux new-session -d -s app2 "zsh -fc 'exec -a claude sleep 120'"
  check 'a real window with Claude shows the mark' retry '_lazyfleet_winrows | plain | grep -E "app2" | gq "✻"'
else
  skip 'a real window with Claude shows the mark' 'this tmux turns tabs in -F output into _, which the windows view still trips over'
fi

(( fails )) && { print -P "\n%F{red}$fails failed%f"; exit 1 }
print -P "\n%F{green}all passed%f"
