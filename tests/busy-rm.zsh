#!/usr/bin/env -S zsh -f
# Tests for the warning before removing a worktree whose session has agents
# running. The unit tests fake the agent list; the last block runs a real
# process in a real (isolated) tmux server.

ROOT=${0:A:h:h}
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg LAZYFLEET_WORKTREES=$SANDBOX/wt TMPDIR=$SANDBOX/tmp
export TMUX_TMPDIR=$SANDBOX GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LAZYFLEET_AGENT_DIR=$SANDBOX/agents
mkdir -p $HOME $TMPDIR
unset TMUX LAZYFLEET_AGENT_ICONS
export LAZYFLEET_TMUX="tmux -L lazyfleet-busy-$$" SHELL=${commands[zsh]}
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
waitpane() { retry "_lazyfleet_tmux capture-pane -p -t '=$1:' 2>/dev/null | grep -qF -- '$2'" }

# a repo "app" with worktrees; the session of worktree feat-x is "app/feat-x"
repo=$SANDBOX/app
git init -q -b main $repo && git -C $repo commit -q --allow-empty -m init
mkwt() { git -C $repo worktree add -q -b $1 $LAZYFLEET_WORKTREES/app/$1 2>/dev/null; print -r -- $LAZYFLEET_WORKTREES/app/$1 }
exists() { [[ -d $1 ]] }
nosession() { ! _lazyfleet_tmux has-session -t "=$1" 2>/dev/null }

# the agent list, faked: "session<TAB>window<TAB>kind<TAB>state<TAB>pane<TAB>visible"
T=$'\t'
FAKE=()
_real_agents=$functions[_lazyfleet_agents]
# like the real one, it only gives the state, pane and visibility with -d
fake_agents() {
  _lazyfleet_agents() {
    local e
    reply=()
    for e in "${FAKE[@]}"; do
      if [[ $1 == -d ]]; then reply+=("$e"); else reply+=("${(pj:\t:)${(@ps:\t:)e}[1,3]}"); fi
    done
  }
}
fake_agents

# --- which agents belong to a session
FAKE=("app/feat-x${T}1${T}claude${T}working${T}%3${T}0" "app/feat-x${T}2${T}copilot${T}${T}%4${T}0" "app/other${T}1${T}omp${T}idle${T}%5${T}0" "app${T}0${T}claude${T}idle${T}%1${T}1")
_lazyfleet_session_agents app/feat-x
check 'both agents of the session are found' test $#reply = 2
check 'an agent is described by kind, window and state' test "$reply[1]" = "claude${T}1${T}working"
check 'an agent whose state is unknown has none' test "$reply[2]" = "copilot${T}2${T}"
_lazyfleet_session_agents app/other
check 'agents of another session are not mixed in' test "$reply" = "omp${T}1${T}idle"
_lazyfleet_session_agents app
check 'a session name is matched whole, not as a prefix' test "$reply" = "claude${T}0${T}idle"
_lazyfleet_session_agents nothing
check 'a session without agents has none' test $#reply = 0
FAKE=()
_lazyfleet_session_agents app/feat-x
check 'no agents at all' test $#reply = 0

# --- the warning text
out=$(_lazyfleet_agents_warning app/feat-x "claude${T}1${T}working" "copilot${T}2${T}" | sed 's/\x1b\[[0-9;]*m//g')
check 'the warning counts the agents' eval 'gq "2 agent(s) running in this worktree.s tmux session (app/feat-x):" <<<$out'
check 'it lists an agent with its state' eval 'gq "^   claude (window 1, working)$" <<<$out'
check 'it lists an agent without a state' eval 'gq "^   copilot (window 2)$" <<<$out'

# --- removing without a terminal: refused, unless -f
w=$(mkwt feat-x)
FAKE=("app/feat-x${T}1${T}claude${T}working${T}%3${T}0")
out=$(_lazyfleet_rm $w </dev/null 2>&1); rc=$?
check 'rm refuses while an agent runs' test $rc = 1
check 'it says why and how to override' eval 'gq "has 1 agent(s) running in session app/feat-x (use -f)" <<<$out'
check 'the worktree is still there' exists $w
out=$(_lazyfleet_rm -f $w </dev/null 2>&1); rc=$?
check '-f removes it anyway' eval 'test $rc = 0 && ! exists $w'

w=$(mkwt feat-y)
FAKE=("app/feat-x${T}1${T}claude${T}working${T}%3${T}0")
out=$(_lazyfleet_rm $w </dev/null 2>&1); rc=$?
check 'an agent in another session does not matter' eval 'test $rc = 0 && ! exists $w'

w=$(mkwt feat-z)
FAKE=()
out=$(_lazyfleet_rm $w </dev/null 2>&1); rc=$?
check 'no agents: removed without a question' eval 'test $rc = 0 && ! exists $w'

# --- with a terminal: asked first (a tmux pane is the terminal)
prompt_rm() {  # $1=worktree dir, $2=session name of the pane
  _lazyfleet_tmux kill-session -t "=$2" 2>/dev/null
  _lazyfleet_tmux new-session -d -s $2 -x 150 -y 12 "zsh -fc 'source $ROOT/lazyfleet.zsh; _lazyfleet_agents() { reply=(\"app/feat-p${T}1${T}claude${T}waiting${T}%3${T}0\") }; _lazyfleet_rm $1; echo rc=\$?; sleep 5'"
}
w=$(mkwt feat-p)
prompt_rm $w ask
check 'rm asks before ending agents' waitpane ask 'Remove anyway? [y/N]'
check 'the prompt names the agent' waitpane ask 'claude (window 1, waiting)'
_lazyfleet_tmux send-keys -t '=ask:' n
check 'no keeps the worktree' waitpane ask 'rc=1'
check 'it is still there' exists $w
_lazyfleet_tmux kill-session -t '=ask'
prompt_rm $w ask
waitpane ask 'Remove anyway? [y/N]'
_lazyfleet_tmux send-keys -t '=ask:' y
check 'yes removes it' waitpane ask 'rc=0'
check 'it is gone' not exists $w

# --- a real process in a real tmux session
w=$(mkwt feat-real)
functions[_lazyfleet_agents]=$_real_agents
_lazyfleet_tmux new-session -d -s app/feat-real "bash -c 'exec -a claude sleep 300'"
check 'a running claude is found in its session' retry '_lazyfleet_session_agents app/feat-real; [[ ${reply[1]%%$T*} == claude ]]'
out=$(_lazyfleet_rm $w </dev/null 2>&1); rc=$?
check 'rm refuses to end it' eval 'test $rc = 1 && exists $w && gq "agent(s) running" <<<$out'
out=$(_lazyfleet_rm -f $w </dev/null 2>&1); rc=$?
check 'rm -f removes the worktree and closes the session' eval 'test $rc = 0 && ! exists $w && nosession app/feat-real'

if (( fails )); then print -P "%F{red}$fails failed%f"; exit 1; fi
print -P "%F{green}all passed%f"
