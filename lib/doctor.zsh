# lazyfleet: lazyfleet doctor: is everything lazyfleet relies on here?
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.

# --- doctor ------------------------------------------------------------------
# lazyfleet doctor: is everything lazyfleet relies on here, and recent enough?
# Every finding is "ok", "warn" (something is reduced, or may not work) or
# "FAIL" (lazyfleet cannot work). The exit status is 1 when anything failed.
# Only fzf's minimum is known to be hard (--style); the zsh, git and tmux
# minimums are conservative, so an older one only warns.

typeset -g _LAZYFLEET_MIN_ZSH=5.1     # zmodload -F
typeset -g _LAZYFLEET_MIN_GIT=2.31    # rev-parse --path-format (_lazyfleet_toplevel)
typeset -g _LAZYFLEET_MIN_TMUX=3.0
typeset -g _LAZYFLEET_MIN_FZF=0.66    # --gutter, --listen=<socket> (install.sh has the same number)
typeset -gi _lazyfleet_doctor_fails=0 _lazyfleet_doctor_warns=0

# level (ok|warn|fail), text, and an optional fix to suggest
_lazyfleet_doctor_report() {
  local level=$1 text=${2//[[:cntrl:]]/ } fix=${3//[[:cntrl:]]/ } tag col= end=
  case $level in
    (ok)   tag='ok  '; col=$'\e[32m' ;;
    (warn) tag='warn'; col=$'\e[33m'; (( ++_lazyfleet_doctor_warns )) ;;
    (fail) tag='FAIL'; col=$'\e[31m'; (( ++_lazyfleet_doctor_fails )) ;;
  esac
  if [[ -t 1 ]]; then end=$'\e[0m'; else col=; fi
  print -r -- "  ${col}${tag}${end}  $text"
  if [[ -n $fix ]]; then print -r -- "        try: $fix"; fi
}

# Judge a tool by the first version number in $2 (what its --version printed):
# name, version text, minimum, level to report when too old, fix
_lazyfleet_doctor_judge() {
  local name=$1 min=$3 old=$4 fix=$5 v
  if [[ $2 =~ '[0-9]+(\.[0-9]+)*' ]]; then
    v=$MATCH
  else
    _lazyfleet_doctor_report warn "$name: cannot tell the version (it printed '${2[1,40]}')"
    return
  fi
  if is-at-least $min $v; then
    _lazyfleet_doctor_report ok "$name $v"
  else
    _lazyfleet_doctor_report $old "$name $v is too old: lazyfleet needs $min or newer" $fix
  fi
}

# A tool that must be there: name, minimum, level when too old, fix, and the
# command that prints its version
_lazyfleet_doctor_need() {
  local name=$1 min=$2 old=$3 fix=$4 out missing=
  shift 4
  # LAZYFLEET_TMUX may be a path, which is not in the command table
  if [[ $1 == */* ]]; then
    [[ -x $1 ]] || missing=1
  elif (( ! $+commands[$1] )); then
    missing=1
  fi
  if [[ -n $missing ]]; then
    _lazyfleet_doctor_report fail "$name is not installed" $fix
    return
  fi
  out=$("$@" 2>&1 </dev/null)
  _lazyfleet_doctor_judge $name ${out%%$'\n'*} $min $old $fix
}

_lazyfleet_doctor_install_hint() { REPLY="macOS: brew install $1    Debian/Ubuntu: sudo apt install $1" }

# the tools around the features that can do without them
_lazyfleet_doctor_optional() {
  if (( $+commands[curl] )); then
    _lazyfleet_doctor_report ok "curl (update check)"
  else
    _lazyfleet_doctor_report warn "curl is not installed: no update check" "sudo apt install curl / brew install curl"
  fi
  if ! _lazyfleet_flag pr_status LAZYFLEET_PR_STATUS on; then
    _lazyfleet_doctor_report ok "pull request marks are off (pr_status=off)"
  elif (( ! $+commands[gh] )); then
    _lazyfleet_doctor_report warn "gh is not installed: no pull request marks" "https://cli.github.com"
  elif ! gh auth token >/dev/null 2>&1 </dev/null; then
    _lazyfleet_doctor_report warn "gh has no login: no pull request marks" "gh auth login"
  else
    _lazyfleet_doctor_report ok "gh is logged in (pull request marks)"
  fi
  # agent state needs Claude Code's hooks, which are installed with jq
  if (( $+commands[claude] )); then
    if (( ! $+commands[jq] )); then
      _lazyfleet_doctor_report warn "jq is not installed: Claude Code hooks cannot be set up" "sudo apt install jq / brew install jq"
    elif _lazyfleet_hooks status >/dev/null 2>&1; then
      _lazyfleet_doctor_report ok "Claude Code hooks are installed (agent state)"
    else
      _lazyfleet_doctor_report warn "Claude Code hooks are not installed: agents show no state" "lazyfleet hooks install"
    fi
  fi
}

# The agent segment in tmux's status line (`#(lazyfleet status)`). tmux runs
# #() through sh with the server's own environment, so a lazyfleet that only a
# shell function or a PATH set in .zshrc provides prints nothing there,
# silently. Checks the running server; without one there is nothing to check.
_lazyfleet_doctor_statusline() {
  local sr cmd tpath d found=
  if ! sr=$(_lazyfleet_tmux show -gv status-right 2>/dev/null); then
    _lazyfleet_doctor_report ok "tmux is not running, so its status line was not checked"
    return
  fi
  if [[ ! $sr =~ '#\(([^ )]*lazyfleet) +status' ]]; then
    _lazyfleet_doctor_report ok "the status line has no agent segment (optional)" "set -g status-right '#(lazyfleet status) %H:%M'"
    return
  fi
  cmd=${match[1]/#\~/$HOME}
  if [[ $cmd == */* ]]; then
    [[ -x $cmd ]] && found=$cmd
  else
    tpath=$(_lazyfleet_tmux show-environment -g PATH 2>/dev/null)
    if [[ $tpath == PATH=* ]]; then
      for d in ${(s.:.)tpath#PATH=}; do
        [[ -x ${d:-.}/$cmd ]] && { found=${d:-.}/$cmd; break }
      done
    fi
  fi
  if [[ -n $found ]]; then
    _lazyfleet_doctor_report ok "the status line's agent segment runs $found"
  else
    _lazyfleet_doctor_report warn "the status line runs '$match[1]', which tmux cannot find: the agent segment stays empty" \
      "use the full path in status-right, e.g. #(${commands[lazyfleet]:-~/.local/bin/lazyfleet} status)"
  fi
}

# the registry: repositories that have gone away
_lazyfleet_doctor_repos() {
  local r
  local -a repos gone
  _lazyfleet_repos
  repos=($reply)
  for r in $repos; do [[ -d $r ]] || gone+=($r); done
  if (( ! $#repos )); then
    _lazyfleet_doctor_report ok "no repositories registered yet" "lazyfleet add [path]"
    return
  fi
  if (( $#repos == 1 )); then
    _lazyfleet_doctor_report ok "1 repository registered"
  else
    _lazyfleet_doctor_report ok "$#repos repositories registered"
  fi
  for r in ${gone[1,5]}; do
    _lazyfleet_doctor_report warn "$r no longer exists" "lazyfleet forget ${r:t}"
  done
  if (( $#gone > 5 )); then _lazyfleet_doctor_report warn "and $(( $#gone - 5 )) more missing repositories"; fi
}

_lazyfleet_doctor() {
  _lazyfleet_doctor_fails=0 _lazyfleet_doctor_warns=0
  print -r -- "lazyfleet doctor"
  if _lazyfleet_version_label; then
    _lazyfleet_doctor_report ok "lazyfleet ${REPLY} in $LAZYFLEET_DIR"
  else
    _lazyfleet_doctor_report ok "lazyfleet from a checkout in $LAZYFLEET_DIR (no version, no update check)"
  fi
  _lazyfleet_doctor_judge zsh $ZSH_VERSION $_LAZYFLEET_MIN_ZSH warn ""
  _lazyfleet_doctor_install_hint git;  _lazyfleet_doctor_need git  $_LAZYFLEET_MIN_GIT  warn $REPLY git --version
  _lazyfleet_doctor_install_hint tmux; _lazyfleet_doctor_need tmux $_LAZYFLEET_MIN_TMUX warn $REPLY ${=LAZYFLEET_TMUX:-tmux} -V
  _lazyfleet_doctor_install_hint fzf;  _lazyfleet_doctor_need fzf  $_LAZYFLEET_MIN_FZF  fail $REPLY fzf --version
  _lazyfleet_doctor_optional
  # what the daily update check last found; nothing to say for a checkout
  _lazyfleet_version && { _lazyfleet_update_status; _lazyfleet_doctor_report ok $REPLY "lazyfleet update" }
  _lazyfleet_doctor_statusline
  _lazyfleet_doctor_repos
  print
  if (( _lazyfleet_doctor_fails )); then
    print -r -- "$_lazyfleet_doctor_fails problem(s), $_lazyfleet_doctor_warns warning(s)."
  elif (( _lazyfleet_doctor_warns )); then
    print -r -- "No problems, $_lazyfleet_doctor_warns warning(s)."
  else
    print -r -- "All good."
  fi
  (( ! _lazyfleet_doctor_fails ))
}
