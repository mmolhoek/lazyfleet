# lazyfleet: Coding agents (Claude Code, Copilot CLI, omp) in tmux panes: finding them, their state, marks, notifications and Claude Code hooks.
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.

# --- coding agents ----------------------------------------------------------
# Claude Code and GitHub Copilot CLI sessions running in tmux panes, found by
# looking at the processes below each pane's shell. This reads command lines,
# so it is a heuristic: it knows the usual ways each tool is started.

# The tools, in the order their marks show, with each one's mark and colour
typeset -ga _LAZYFLEET_AGENT_KINDS=(claude copilot omp)
typeset -gA _LAZYFLEET_AGENT_ICON=(claude ✻ copilot ✦ omp π)
typeset -gA _LAZYFLEET_AGENT_COLOR=(claude $'\e[38;5;208m' copilot $'\e[35m' omp $'\e[36m')

# REPLY=claude, copilot or omp if command line $1 is one of those tools, else empty
_lazyfleet_agent_kind() {
  local -a w
  local x a
  w=(${(z)1})
  REPLY=
  case ${w[1]:t} in
    (claude) REPLY=claude ;;
    (copilot) REPLY=copilot ;;
    (omp) REPLY=omp ;;
    # the native installer runs a versioned binary: .../claude/versions/2.0.1
    (<->.<->.<->) [[ ${w[1]} == */claude/* ]] && REPLY=claude ;;
    (node|bun|deno)
      for x in ${w[2,-1]}; do [[ $x == -* ]] || { a=$x; break }; done
      case $a in
        (*/@anthropic-ai/claude-code/*|*/claude-code/*|*/bin/claude) REPLY=claude ;;
        (*/@github/copilot/*|*/bin/copilot) REPLY=copilot ;;
        (*/@oh-my-pi/*|*/bin/omp) REPLY=omp ;;
      esac ;;
    (gh) [[ ${w[2]} == copilot ]] && REPLY=copilot ;;
  esac
  [[ -n $REPLY ]]
}

# Where the hook script (bin/lazyfleet-hook) keeps what each agent is doing
_lazyfleet_agent_dir() { REPLY=${LAZYFLEET_AGENT_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/lazyfleet/agents} }

# The file name part that identifies a pane: its tmux server's socket plus its
# id, with everything but letters and digits turned into "_" (as the hook does)
_lazyfleet_agent_key() { local s=$1$2; REPLY=${s//[^A-Za-z0-9]/_} }

# REPLY=what an agent is doing: working, waiting, done, idle, or empty when
# unknown. $1 kind, $2 tmux socket, $3 pane id. This is the hook's record, and
# for Claude Code the screen has the last word on "working": a turn that was
# interrupted with Esc never runs the hook that ends it, and a session whose
# hooks are not installed has no record at all.
_lazyfleet_agent_state() {
  local kind=$1 st= ts file busy=
  REPLY=
  [[ -n $3 ]] || return 0
  _lazyfleet_agent_dir; file=$REPLY
  _lazyfleet_agent_key $2 $3; file=$file/$kind.$REPLY
  [[ -r $file ]] && read -r st ts <$file
  [[ $st == (working|waiting|done|idle) ]] || st=
  if [[ $kind == claude && ( -z $st || $st == working ) ]]; then
    _lazyfleet_tmux capture-pane -p -t $3 2>/dev/null | tail -n 15 | grep -qi 'esc to interrupt' && busy=1
    if [[ -n $busy ]]; then st=working
    elif [[ $st == working ]]; then st=idle
    fi
  fi
  REPLY=$st
}

# reply=("session<TAB>window<TAB>claude|copilot|omp" ...): one entry per tmux pane
# that has such a tool running below its shell (or as its shell). With -d each
# entry goes on with "<TAB>state<TAB>pane id<TAB>visible" (visible is 1 when
# someone is looking at the pane right now), and the hook's records of agents
# that have stopped are removed.
_lazyfleet_agents() {
  local line pid p n detail= state vis key
  local -a f live
  local -A parent kinds panes seen
  [[ $1 == -d ]] && detail=1
  reply=()
  (( $+commands[ps] )) || return 0
  _lazyfleet_agent_panes || return 0
  for line in $reply; do panes[${line%%$'\t'*}]=${line#*$'\t'}; done
  reply=()
  (( $#panes )) || return 0
  _lazyfleet_agent_procs
  for line in $reply; do
    f=("${(@ps:\t:)line}")
    parent[$f[1]]=$f[2]
    [[ -n $f[3] ]] && kinds[$f[1]]=$f[3]
  done
  reply=()
  for pid in ${(k)kinds}; do
    # up the process tree to the pane the agent runs in
    p=$pid n=0
    while [[ -n $p && $p != 0 && $p != 1 && -z $panes[$p] ]] && (( n++ < 64 )); do p=$parent[$p]; done
    [[ -n $panes[$p] && -z $seen[$p:$kinds[$pid]] ]] || continue
    seen[$p:$kinds[$pid]]=1
    f=("${(@ps:\t:)panes[$p]}")
    line="$f[1]"$'\t'"$f[2]"$'\t'"$kinds[$pid]"
    if [[ -n $detail ]]; then
      _lazyfleet_agent_state $kinds[$pid] $f[4] $f[3]; state=$REPLY
      vis=1; [[ $f[5] == 0 ]] && vis=0
      # finished work that is on screen has been seen: no more "done"
      [[ $state == done && $vis == 1 ]] && { state=idle; _lazyfleet_agent_set $kinds[$pid] $f[4] $f[3] idle }
      line+=$'\t'"$state"$'\t'"$f[3]"$'\t'"$vis"
      _lazyfleet_agent_key $f[4] $f[3]; live+=("$kinds[$pid].$REPLY")
    fi
    reply+=("$line")
  done
  local -a found=("${(@)reply}")
  [[ -n $detail ]] && _lazyfleet_agent_prune $live ${(u)${(v)panes}}
  reply=(${(o)found})
}

# reply=("pid<TAB>session<TAB>window<TAB>pane id<TAB>socket<TAB>on screen" ...),
# one per tmux pane (pid: the pane's shell). "on screen" is empty when the
# pane is what an attached client shows, 0 when it is not. Fails without tmux.
_lazyfleet_agent_panes() {
  # tmux 3.4 turns tabs in -F output into "_", so split on a printable separator
  local sep='@@lf@@' out line
  local -a f
  reply=()
  out=$(_lazyfleet_tmux list-panes -a -F "#{pane_pid}${sep}#{session_name}${sep}#{window_index}${sep}#{pane_id}${sep}#{socket_path}${sep}#{session_attached}#{window_active}#{pane_active}" 2>/dev/null) || return 1
  for line in ${(f)out}; do
    line=${line//$sep/$'\t'}
    f=("${(@ps:\t:)line}")
    [[ $f[1] == <-> && -n $f[2] ]] || continue
    reply+=("$f[1]"$'\t'"$f[2]"$'\t'"$f[3]"$'\t'"$f[4]"$'\t'"$f[5]"$'\t'"${${f[6]:#<1->11}:+0}")
  done
}

# reply=("pid<TAB>parent pid<TAB>agent kind or empty" ...), every process
_lazyfleet_agent_procs() {
  local line pid ppid args kind
  reply=()
  for line in ${(f)"$(ps -axo pid=,ppid=,args= 2>/dev/null)"}; do
    read -r pid ppid args <<<$line
    [[ $pid == <-> && $ppid == <-> ]] || continue
    kind=
    # most processes are no agent: only look closer at lines that could be
    [[ $args == *(claude|copilot|omp|gh)* ]] && _lazyfleet_agent_kind $args && kind=$REPLY
    reply+=("$pid"$'\t'"$ppid"$'\t'"$kind")
  done
}

# Remove the hook's records for panes of the tmux servers seen in this round
# that no longer run that agent. Args: the live "kind.key" names, then the
# panes' "session TAB window TAB pane TAB socket TAB visible" values.
_lazyfleet_agent_prune() {
  local rec v sk
  local -a live socks f
  local -A servers
  for v in "$@"; do
    if [[ $v == *$'\t'* ]]; then
      f=("${(@ps:\t:)v}"); _lazyfleet_agent_key $f[4] ''; servers[$REPLY]=1
    else live+=($v)
    fi
  done
  _lazyfleet_agent_dir
  for rec in $REPLY/*(N.:t); do
    [[ ${live[(Ie)$rec]} -gt 0 ]] && continue
    sk=${rec#*.}
    for v in ${(k)servers}; do
      # a pane's part of the key is always "_" and its number
      [[ $sk == ${v}_<-> ]] && { rm -f $REPLY/$rec 2>/dev/null; break }
    done
  done
}

# Record an agent's state the way bin/lazyfleet-hook does: kind, tmux socket,
# pane id, state
_lazyfleet_agent_set() {
  local dir file
  _lazyfleet_agent_dir; dir=$REPLY
  [[ -d $dir ]] || return 0
  _lazyfleet_agent_key $2 $3; file=$dir/$1.$REPLY
  print -r -- "$4 $EPOCHSECONDS" >$file.$$ 2>/dev/null && mv -f $file.$$ $file 2>/dev/null || rm -f $file.$$ 2>/dev/null
  return 0
}

# Print a tmux status-bar segment naming the sessions with an agent that waits
# for you ("! app") or has finished ("✓ api"); agents you can see right now do
# not count, and nothing is printed when there are none. For status-right:
#   #(lazyfleet status)
# -p prints plain text, without tmux style codes.
_lazyfleet_status() {
  local -a o_p f waiting finished
  local line out= s
  zparseopts -D -E p=o_p
  _lazyfleet_agents -d
  for line in $reply; do
    f=("${(@ps:\t:)line}")
    [[ $f[6] == 0 ]] || continue
    s=$f[1]; (( $#o_p )) || s=${s//\#/##}
    case $f[4] in
      (waiting) waiting+=($s) ;;
      (done) finished+=($s) ;;
    esac
  done
  waiting=(${(u)waiting}) finished=(${(u)finished})
  if (( $#waiting )); then
    (( $#o_p )) && out+="! ${(j: :)waiting}" || out+="#[fg=yellow,bold]! ${(j: :)waiting}#[default]"
  fi
  if (( $#finished )); then
    out+="${out:+ }"
    (( $#o_p )) && out+="✓ ${(j: :)finished}" || out+="#[fg=green]✓ ${(j: :)finished}#[default]"
  fi
  [[ -n $out ]] && print -r -- "$out "
  return 0
}

# Called in the background by bin/lazyfleet-hook (inside the agent's pane) when
# an agent starts waiting for you or finishes: refresh the status bars, and
# unless you are looking at that pane, show a short message on the clients that
# are in other sessions. agent_notify=off (or LAZYFLEET_AGENT_NOTIFY=off) keeps
# the messages away; the status segment stays.
_lazyfleet_agent_notify() {
  local sep='@@lf@@' kind=$1 st=$2 info sess vis msg line c
  local -a f
  [[ -n $TMUX_PANE && $kind == (claude|copilot|omp) && $st == (waiting|done) ]] || return 0
  info=$(_lazyfleet_tmux display-message -p -t $TMUX_PANE "#{session_name}${sep}#{session_attached}#{window_active}#{pane_active}" 2>/dev/null) || return 0
  sess=${info%%${sep}*} vis=${info##*${sep}}
  _lazyfleet_tmux refresh-client -S 2>/dev/null
  _lazyfleet_flag agent_notify LAZYFLEET_AGENT_NOTIFY on || return 0
  [[ $vis == <1->11 ]] && return 0
  case $st in
    (waiting) msg="$_LAZYFLEET_AGENT_ICON[$kind] $sess needs you" ;;
    (done) msg="$_LAZYFLEET_AGENT_ICON[$kind] $sess is done" ;;
  esac
  msg=${msg//\#/##}
  for line in ${(f)"$(_lazyfleet_tmux list-clients -F "#{client_name}${sep}#{client_session}" 2>/dev/null)"}; do
    c=${line%%${sep}*}
    [[ ${line#*${sep}} == $sess ]] && continue
    _lazyfleet_tmux display-message -c $c -d 4000 -- $msg 2>/dev/null
  done
  return 0
}

# --- Claude Code hooks --------------------------------------------------------
# `lazyfleet hooks install` adds hooks to Claude Code's settings.json that run
# bin/lazyfleet-hook, so lazyfleet knows when Claude works, waits for you or is
# done. Entries of ours are told apart by "lazyfleet-hook" in their command;
# everything else in the file is left as it is.

# The jq filters. Our events: name, state, and (for Notification) which
# notifications mean "waiting for you"
typeset -g _LAZYFLEET_HOOKS_JQ_DEF='
  def events: [
    {n:"SessionStart", s:"idle"}, {n:"UserPromptSubmit", s:"working"},
    {n:"PostToolUse", s:"working"},
    {n:"Notification", s:"waiting", m:"permission_prompt|elicitation_dialog"},
    {n:"Stop", s:"done"}, {n:"SessionEnd", s:"clear"} ];
  def ours: (.hooks // []) | any(.[]; (.command // "") | contains("lazyfleet-hook"));
  def without_ours: map(select(ours | not));'
typeset -g _LAZYFLEET_HOOKS_JQ_INSTALL='
  reduce events[] as $e (.;
    .hooks[$e.n] = ((.hooks[$e.n] // []) | without_ours)
      + [ ({hooks: [{type: "command", command: ($hook + " claude " + $e.s)}]}
           + (if $e.m then {matcher: $e.m} else {} end)) ])'
typeset -g _LAZYFLEET_HOOKS_JQ_UNINSTALL='
  if has("hooks") and (.hooks | type == "object") then
    .hooks |= (map_values(if type == "array" then without_ours else . end)
               | with_entries(select(.value != [])))
    | if .hooks == {} then del(.hooks) else . end
  else . end'
typeset -g _LAZYFLEET_HOOKS_JQ_COUNT='
  [ .hooks // {} | to_entries[] | select(.value | type == "array" and any(.[]; ours)) ] | length'

# lazyfleet hooks [install|uninstall|status]
_lazyfleet_hooks() {
  local sub=${1:-status} file hook jq tmp n bak
  (( $+commands[jq] )) || { _lazyfleet_err "hooks needs jq (https://jqlang.org)"; return 1 }
  file=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
  bak=$file.lazyfleet.bak
  if [[ -e $file ]] && ! jq -e . $file >/dev/null 2>&1; then
    _lazyfleet_err "$file is not valid JSON; left alone"; return 1
  fi
  case $sub in
    (status)
      n=0; [[ -r $file ]] && n=$(jq -r "$_LAZYFLEET_HOOKS_JQ_DEF $_LAZYFLEET_HOOKS_JQ_COUNT" $file)
      if (( n )); then print -r -- "Claude Code hooks installed ($n events) in $file"
      else print -r -- "Claude Code hooks not installed. Install: lazyfleet hooks install"; return 1
      fi ;;
    (install|uninstall)
      if [[ $sub == install ]]; then
        hook=$LAZYFLEET_DIR/bin/lazyfleet-hook
        [[ -x $hook ]] || { _lazyfleet_err "no hook script at $hook"; return 1 }
        hook=${(qq)hook}
        jq="$_LAZYFLEET_HOOKS_JQ_DEF $_LAZYFLEET_HOOKS_JQ_INSTALL"
      else
        [[ -e $file ]] || { print -r -- "Nothing to remove: $file does not exist"; return 0 }
        jq="$_LAZYFLEET_HOOKS_JQ_DEF $_LAZYFLEET_HOOKS_JQ_UNINSTALL"
      fi
      mkdir -p ${file:h} || return 1
      if [[ -e $file && ! -e $bak ]]; then
        cp -p $file $bak || { _lazyfleet_err "could not back up $file"; return 1 }
        print -r -- "Backed up $file to $bak"
      fi
      tmp=$file.lazyfleet.$$
      if [[ -e $file ]]; then jq --arg hook "$hook" "$jq" $file >$tmp
      else print -r -- '{}' | jq --arg hook "$hook" "$jq" >$tmp
      fi || { rm -f $tmp; _lazyfleet_err "could not update $file"; return 1 }
      [[ -e $file ]] && chmod --reference=$file $tmp 2>/dev/null
      mv -f $tmp $file || { rm -f $tmp; return 1 }
      if [[ $sub == install ]]; then print -r -- "Claude Code hooks installed in $file"
      else print -r -- "Claude Code hooks removed from $file"
      fi ;;
    (*) _lazyfleet_err "usage: lazyfleet hooks [install|uninstall|status]"; return 1 ;;
  esac
}

# are the agent icons on? (agent_icons=off or LAZYFLEET_AGENT_ICONS=off turns them off)
_lazyfleet_agent_icons_on() {
  _lazyfleet_flag agent_icons LAZYFLEET_AGENT_ICONS on
}

# What each state looks like after an agent's icon, most urgent first
typeset -ga _LAZYFLEET_AGENT_STATES=(waiting done working)
typeset -gA _LAZYFLEET_AGENT_STATE_MARK=(waiting ! done ✓ working …)
typeset -gA _LAZYFLEET_AGENT_STATE_COLOR=(waiting $'\e[1;33m' done $'\e[32m' working $'\e[2m')

# REPLY=the marks for the agents given as arguments, in a fixed order, like
# "✻2! π✓": the icon, a count above one, and the most urgent state of that
# kind (! waiting for you, ✓ done, … working; idle shows nothing). Coloured,
# unless the first argument is -p. The arguments are kind=count and
# kind:state=count, so an absent kind can not shift the others.
_lazyfleet_agent_marks() {
  local plain= kind n out= col end arg st sm sc
  local -A cnt
  [[ $1 == -p ]] && { plain=1; shift }
  for arg in "$@"; do cnt[${arg%%=*}]=${arg#*=}; done
  for kind in $_LAZYFLEET_AGENT_KINDS; do
    n=${cnt[$kind]:-0}
    (( n )) || continue
    col=$_LAZYFLEET_AGENT_COLOR[$kind] end=$'\e[0m'
    [[ -n $plain ]] && col= end=
    out+="${out:+ }${col}${_LAZYFLEET_AGENT_ICON[$kind]}${${n:#1}}${end}"
    for st in $_LAZYFLEET_AGENT_STATES; do
      (( ${cnt[$kind:$st]:-0} )) || continue
      sc=$_LAZYFLEET_AGENT_STATE_COLOR[$st]
      [[ -n $plain ]] && sc=
      out+="${sc}${_LAZYFLEET_AGENT_STATE_MARK[$st]}${end}"
      break
    done
  done
  REPLY=$out
}

# Count the agents from _lazyfleet_agents into the caller's associative array
# agtally, keyed "session:kind" (or, with w, "session:window:kind") and, for
# agents whose state is known, "...:kind:state"
_lazyfleet_agent_tally() {
  local line k
  local -a f
  _lazyfleet_agents -d
  for line in $reply; do
    f=("${(@ps:\t:)line}")
    k=$f[1]; [[ $1 == w ]] && k+=:$f[2]
    agtally[$k:$f[3]]=$(( ${agtally[$k:$f[3]]:-0} + 1 ))
    [[ -n $f[4] ]] && agtally[$k:$f[3]:$f[4]]=$(( ${agtally[$k:$f[3]:$f[4]]:-0} + 1 ))
  done
}

# REPLY=the marks for key $1 (a session, or session:window) from the caller's
# agtally; -p as $2 for plain marks
_lazyfleet_agent_marks_at() {
  local kind st
  local -a mk
  for kind in $_LAZYFLEET_AGENT_KINDS; do
    [[ -n ${agtally[$1:$kind]} ]] || continue
    mk+=($kind=${agtally[$1:$kind]})
    for st in $_LAZYFLEET_AGENT_STATES; do
      [[ -n ${agtally[$1:$kind:$st]} ]] && mk+=($kind:$st=${agtally[$1:$kind:$st]})
    done
  done
  _lazyfleet_agent_marks $2 $mk
}
