# lazyfleet: Settings, and the config lookup for a repo (.lazyfleet, projects/<repo>.conf, config).
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.

# REPLY=value of key $2 in file $1. Lines indented deeper than the key= line
# continue the value (minus the first one's indent). With repo $3, only
# [sections] naming that repo (by name or path) count; with -, only lines
# before any section.
_lazyfleet_conf_read() {
  local key=$2 repo=$3 line lead text sect ind on=1 hit= kind
  local -a val
  [[ -n $repo && $repo != - ]] && on=
  for line in "${(@f)$(<$1)}"; do
    lead=${line%%[^[:space:]]*}; text=${line#$lead}
    if [[ -n $hit ]]; then
      if [[ -z $text ]] || (( $#lead > kind )); then
        [[ -z $ind && -n $text ]] && ind=$lead
        val+=("${line#$ind}")
        continue
      fi
      break
    fi
    if [[ -n $repo && $text == '['*']' ]]; then
      typeset -g _lazyfleet_sect=${${text#\[}%\]}
      sect=${${_lazyfleet_sect}%/}; sect=${sect/#\~/$HOME}
      [[ $sect == ${repo:t} || ( $sect == */* && ${sect:A} == ${repo:A} ) ]] && on=1 || on=
    elif [[ -n $on && $text == $key=* ]]; then
      hit=1; kind=$#lead; val=("${text#$key=}")
    fi
  done
  [[ -n $hit ]] || return 1
  # "key=" with the value on the next lines; trailing blank lines
  [[ -z $val[1] ]] && (( $#val > 1 )) && shift val
  while (( $#val > 1 )) && [[ -z $val[-1] ]]; do val[-1]=(); done
  REPLY=${(F)val}
}

# REPLY=value of key $1 for worktree $2 of repo $3, from the first of:
# ~/.config/lazyfleet/projects/<repo>.conf, the repo's [section] in
# ~/.config/lazyfleet/config (older layout), .lazyfleet in the worktree, then
# in the repo. _lazyfleet_from says which one it was.
# The worktree's own .lazyfleet comes from whatever branch it has checked out,
# maybe somebody else's (new --pr): its value only counts when the main
# worktree's .lazyfleet says the same, or trust_branch_config is on. A value
# that was passed over sets _lazyfleet_ignored to the key.
_lazyfleet_conf() {
  local f
  typeset -g _lazyfleet_from= _lazyfleet_ignored=
  _lazyfleet_projconf $3; f=$REPLY
  if [[ -r $f ]] && _lazyfleet_conf_read $f $1; then
    _lazyfleet_from="${f/#$HOME/~}"
    return 0
  fi
  _lazyfleet_regfile; f=${REPLY:h}/config
  if [[ -r $f ]] && _lazyfleet_conf_read $f $1 $3; then
    _lazyfleet_from="${f/#$HOME/~} [$_lazyfleet_sect]"
    return 0
  fi
  for f in $2/.lazyfleet $3/.lazyfleet; do
    [[ -r $f ]] && _lazyfleet_conf_read $f $1 || continue
    if [[ $f == $2/* ]] && ! _lazyfleet_branchconf_trusted $1 $REPLY $3; then
      _lazyfleet_ignored=$1
      continue
    fi
    [[ $f == $2/* ]] && _lazyfleet_from=.lazyfleet || _lazyfleet_from="${f/#$HOME/~}"
    return 0
  done
  REPLY=
  return 1
}

# Is $2, the value of key $1 in a new worktree's own .lazyfleet, fine to use
# for repo $3? Yes when the repo's main worktree has the same value, or
# trust_branch_config=on (LAZYFLEET_TRUST_BRANCH_CONFIG) says to trust branches.
# Leaves REPLY alone.
_lazyfleet_branchconf_trusted() {
  emulate -L zsh
  local key=$1 val=$2 repo=$3 REPLY
  _lazyfleet_setting trust_branch_config LAZYFLEET_TRUST_BRANCH_CONFIG off
  [[ ${REPLY:l} == (on|yes|true|1) ]] && return 0
  [[ -r $repo/.lazyfleet ]] && _lazyfleet_conf_read $repo/.lazyfleet $key && [[ $REPLY == $val ]]
}

# REPLY=path of repo $1's own config file
_lazyfleet_projconf() {
  _lazyfleet_regfile; REPLY=${REPLY:h}/projects/${1:t}.conf
}

# REPLY=global setting $1: $2 (an env var) if set, else the top of
# ~/.config/lazyfleet/config (before any [section]), else default $3
_lazyfleet_setting() {
  local f
  [[ -n ${(P)2} ]] && { REPLY=${(P)2}; return }
  _lazyfleet_regfile; f=${REPLY:h}/config
  [[ -r $f ]] && _lazyfleet_conf_read $f $1 - && [[ -n $REPLY ]] && return
  REPLY=$3
}
