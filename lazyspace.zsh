# lazyspace — a minimal Supacode: git worktrees, each with its own tmux session.
# Source this file from .zshrc, then run `lazyspace` (TUI) or `lazyspace help`.

typeset -g LAZYSPACE_DIR=${${(%):-%x}:A:h}
typeset -g _LAZYSPACE_LETTERS='j,k,n,d,r,a,w,R,q'
typeset -g _LAZYSPACE_FOOTER_WT=$'↵ open  n new  a add  d del  r run
⇥ repos  w windows  / find  q quit'
typeset -g _LAZYSPACE_FOOTER_REPO=$'↵ worktrees   n new   a add   d forget
⇥ windows   / find  R reload  q quit'
typeset -g _LAZYSPACE_FOOTER_WIN=$'↵ switch  d kill
⇥ views  / find
R reload  q quit'
# list/Details split: the Windows view is mostly preview
typeset -g _LAZYSPACE_PW='right,50%' _LAZYSPACE_PW_WIN='right,70%'

# --- plumbing ---------------------------------------------------------------

# A tmux server keeps the environment it started with and hands it to every
# session, so never pass it an exported FPATH containing our dir: compinit in
# each session's shell would flag the dir as insecure.
_lazyspace_tmux() {
  if [[ ${(t)FPATH} == *export* ]]; then
    FPATH=${(j.:.)${fpath:#$LAZYSPACE_DIR}} command ${=LAZYSPACE_TMUX:-tmux} "$@"
  else
    command ${=LAZYSPACE_TMUX:-tmux} "$@"
  fi
}

_lazyspace_err() { print -ru2 -- "lazyspace: $*"; return 1 }

_lazyspace_pause() { print -n 'press any key '; read -sk1 </dev/tty; print }

_lazyspace_regfile() { REPLY=${XDG_CONFIG_HOME:-$HOME/.config}/lazyspace/repos }

# Sort reply by the key that function $1 puts in REPLY for each element
# (case-insensitive)
_lazyspace_sortby() {
  local e
  local -a keyed
  for e in $reply; do $1 $e; keyed+=("${REPLY:l}"$'\0'"$e"); done
  reply=(${${(o)keyed}#*$'\0'})
}
_lazyspace_key_name() { REPLY=${1:t} }
_lazyspace_key_branch() { REPLY=${${1#*$'\t'}%$'\t'*} }

# reply=(registered repo paths, by name)
_lazyspace_repos() {
  _lazyspace_regfile
  reply=()
  [[ -r $REPLY ]] && reply=(${(f)"$(<$REPLY)"})
  _lazyspace_sortby _lazyspace_key_name
}

# REPLY=main worktree of the repo containing $1 (default $PWD)
_lazyspace_toplevel() {
  local d=${${1:-$PWD}:A} gd common
  # fast path (no fork) for worktree roots
  if [[ -d $d/.git ]]; then
    REPLY=$d; return 0
  elif [[ -f $d/.git ]]; then
    gd=$(<$d/.git); gd=${gd#gitdir: }
    [[ $gd == /* ]] || gd=${d}/$gd
    [[ $gd == */.git/worktrees/* ]] && { REPLY=${gd:A}; REPLY=${REPLY%/.git/worktrees/*}; return 0 }
  fi
  common=$(git -C $d rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [[ ${common:t} == .git ]] && REPLY=${common:h} || REPLY=$common
}

# REPLY=registered repo matching a name or path
_lazyspace_find_repo() {
  local r
  _lazyspace_repos
  for r in $reply; do
    [[ ${r:t} == $1 || $r == ${1:A} ]] && { REPLY=$r; return 0 }
  done
  return 1
}

# REPLY=branch name from a HEAD file
_lazyspace_head() {
  local h=$(<$1)
  [[ $h == 'ref: refs/heads/'* ]] && REPLY=${h#ref: refs/heads/} || REPLY='(detached)'
}

# reply=("path<TAB>branch<TAB>ismain" ...) for repo $1, by branch
_lazyspace_worktrees() {
  _lazyspace_worktrees_raw $1
  _lazyspace_sortby _lazyspace_key_branch
}

_lazyspace_worktrees_raw() {
  local g=$1/.git d wt line br m skip i=0
  reply=()
  if [[ -d $g ]]; then
    # read .git directly: no fork
    _lazyspace_head $g/HEAD; reply+=("$1"$'\t'"$REPLY"$'\t'1)
    for d in $g/worktrees/*(N/); do
      [[ -r $d/gitdir ]] || continue
      wt=$(<$d/gitdir); wt=${wt%/.git}
      [[ $wt == /* ]] || wt=${${d}/$wt:A}
      [[ -d $wt ]] || continue
      _lazyspace_head $d/HEAD; reply+=("$wt"$'\t'"$REPLY"$'\t'0)
    done
    return
  fi
  for line in ${(f)"$(git -C $1 worktree list --porcelain 2>/dev/null)"} 'worktree '; do
    case $line in
      ('worktree '*)
        [[ -n $wt && -z $skip ]] && reply+=("$wt"$'\t'"$br"$'\t'"$m")
        wt=${line#worktree }; br='(detached)'; skip=; m=$(( i++ == 0 )) ;;
      ('branch '*) br=${line#branch refs/heads/} ;;
      (bare|prunable*) skip=1 ;;
    esac
  done
}

# REPLY=tmux session name for worktree $2 of repo $1 ($3=1 if main worktree)
_lazyspace_session() {
  REPLY=${1:t}
  [[ $3 == 1 ]] || REPLY+=/${2:t}
  REPLY=${REPLY//[.:]/-}
}

# REPLY=value of key $2 in file $1. Lines indented deeper than the key= line
# continue the value (minus the first one's indent). With repo $3, only
# [sections] naming that repo (by name or path) count; with -, only lines
# before any section.
_lazyspace_conf_read() {
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
      sect=${${${text#\[}%\]}%/}; sect=${sect/#\~/$HOME}
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

# REPLY=value of key $1 for worktree $2 of repo $3: the repo's [section] in
# ~/.config/lazyspace/config wins, then .lazyspace in the worktree, then the repo
_lazyspace_conf() {
  local f
  _lazyspace_regfile; f=${REPLY:h}/config
  [[ -r $f ]] && _lazyspace_conf_read $f $1 $3 && return 0
  for f in $2/.lazyspace $3/.lazyspace; do
    [[ -r $f ]] && _lazyspace_conf_read $f $1 && return 0
  done
  REPLY=
  return 1
}

# REPLY=global setting $1: $2 (an env var) if set, else the top of
# ~/.config/lazyspace/config (before any [section]), else default $3
_lazyspace_setting() {
  local f
  [[ -n ${(P)2} ]] && { REPLY=${(P)2}; return }
  _lazyspace_regfile; f=${REPLY:h}/config
  [[ -r $f ]] && _lazyspace_conf_read $f $1 - && [[ -n $REPLY ]] && return
  REPLY=$3
}

# Type command $2 into tmux target $1 and press Enter. Multi-line commands are
# sourced from file $3 (in a private tmp dir), so later lines aren't typed into
# whatever an earlier one runs.
_lazyspace_type() {
  local cmd=$2 f
  if [[ $cmd == *$'\n'* ]]; then
    f=${TMPDIR:-/tmp}/lazyspace-$UID
    mkdir -p -m 700 $f || return 1
    f+=/$3
    print -r -- $cmd >| $f
    cmd="source ${(q)f}"
  fi
  _lazyspace_tmux send-keys -t $1 -l -- "$cmd" \; send-keys -t $1 Enter
}

# REPLY=worktree path for a path, session name, branch or dir name
_lazyspace_resolve() {
  [[ -d $1 ]] && { REPLY=${1:A}; return 0 }
  local repo e p br
  local -a repos hits
  _lazyspace_repos; repos=($reply)
  for repo in $repos; do
    _lazyspace_worktrees $repo
    for e in $reply; do
      p=${e%%$'\t'*}; br=${${e#*$'\t'}%$'\t'*}
      _lazyspace_session $repo $p ${e##*$'\t'}
      [[ $1 == $REPLY || $1 == $br || $1 == ${repo:t}/$br || $1 == ${p:t} ]] && hits+=($p)
    done
  done
  hits=(${(u)hits})
  (( $#hits == 1 )) && { REPLY=$hits[1]; return 0 }
  REPLY=$#hits
  return 1
}

# Create the worktree's session (detached) if needed; REPLY=session name
_lazyspace_ensure() {
  local p=${1:A} repo m=0
  _lazyspace_toplevel $p || { _lazyspace_err "not a git worktree: $p"; return 1 }
  repo=$REPLY
  [[ $p == ${repo:A} ]] && m=1
  _lazyspace_session $repo $p $m
  _lazyspace_tmux has-session -t "=$REPLY" 2>/dev/null ||
    _lazyspace_tmux new-session -d -s $REPLY -c $p
}

_lazyspace_open_path() {
  _lazyspace_ensure $1 || return
  _lazyspace_attach "=$REPLY"
}

# Show window $1 ("=session:index"): select it, then attach/switch
_lazyspace_open_window() {
  _lazyspace_tmux select-window -t "$1" || return
  _lazyspace_attach "${1%:*}"
}

# Switch to session $1 (inside tmux) or attach to it (outside)
_lazyspace_attach() {
  if [[ -n $TMUX ]]; then
    _lazyspace_tmux switch-client -t "$1"
  else
    # tmux refuses a stdin named /dev/tty (as under fzf's become), so attach
    # through the real controlling terminal device, opened read-write: the
    # server draws through the client's stdin, a read-only fd stays blank
    local t=${$(ps -o tty= -p $$ 2>/dev/null)// /}
    if [[ -c /dev/$t ]]; then
      _lazyspace_tmux attach-session -t "$1" <>/dev/$t
    else
      _lazyspace_tmux attach-session -t "$1"
    fi
  fi
}

# "* ↑1 ↓2" for worktree $1
_lazyspace_wtstatus() {
  local out= ab a b
  [[ -n $(git -C $1 status --porcelain --untracked-files=no 2>/dev/null) ]] && out='*'
  if ab=$(git -C $1 rev-list --left-right --count 'HEAD...@{u}' 2>/dev/null); then
    a=${ab%%[[:space:]]*}; b=${ab##*[[:space:]]}
    (( a )) && out+=" ↑$a"
    (( b )) && out+=" ↓$b"
  fi
  print -rn -- ${out# }
}

# --- rows for the TUI: "kind<TAB>path<TAB>display" ---------------------------

# _lazyspace_rows [-s (with git status)] [-p (plain)] [repo name filter]
_lazyspace_rows() {
  setopt local_options no_monitor no_notify
  local -a o_s o_p
  zparseopts -D -E s=o_s p=o_p
  local only=$1 repo e p s i tmp wn=0 wb=0
  local c_repo=$'\e[34m' c_live=$'\e[32m' c_st=$'\e[33m' c_off=$'\e[0m'
  (( $#o_p )) && c_repo= c_live= c_st= c_off=
  local -A live
  local -a repos paths names branches lives stats
  for s in ${(f)"$(_lazyspace_tmux list-sessions -F '#S' 2>/dev/null)"}; do live[$s]=1; done
  _lazyspace_repos; repos=($reply)
  for repo in $repos; do
    [[ -n $only && ${repo:t} != $only ]] && continue
    _lazyspace_worktrees $repo
    for e in $reply; do
      p=${e%%$'\t'*}
      _lazyspace_session $repo $p ${e##*$'\t'}
      paths+=($p); names+=(${repo:t}); branches+=(${${e#*$'\t'}%$'\t'*})
      lives+=("${live[$REPLY]:+●}"); stats+=('')
      (( $#names[-1] > wn )) && wn=$#names[-1]
      (( $#branches[-1] > wb )) && wb=$#branches[-1]
    done
  done
  if (( $#o_s && $#paths )); then
    tmp=${TMPDIR:-/tmp}/lazyspace.$$.$RANDOM
    mkdir -p $tmp
    for i in {1..$#paths}; do _lazyspace_wtstatus $paths[i] >$tmp/$i & done
    wait
    for i in {1..$#paths}; do stats[i]=$(<$tmp/$i); done
    rm -rf $tmp
  fi
  for (( i = 1; i <= $#paths; i++ )); do
    printf 'w\t%s\t%s%-*s%s  %-*s  %s%1s%s %s%s%s\n' $paths[i] \
      "$c_repo" $wn $names[i] "$c_off" $wb $branches[i] \
      "$c_live" "$lives[i]" "$c_off" "$c_st" "$stats[i]" "$c_off"
  done
}

_lazyspace_reporows() {
  local repo s n l wn=0
  local -a repos sessions
  sessions=(${(f)"$(_lazyspace_tmux list-sessions -F '#S' 2>/dev/null)"})
  _lazyspace_repos; repos=($reply)
  for repo in $repos; do (( $#repo:t > wn )) && wn=$#repo:t; done
  for repo in $repos; do
    _lazyspace_worktrees $repo; n=$#reply
    l=0
    for s in $sessions; do [[ $s == ${repo:t} || $s == ${repo:t}/* ]] && (( l++ )); done
    printf 'r\t%s\t\e[34m%-*s\e[0m  %d worktree%s  \e[32m%s\e[0m\n' $repo $wn ${repo:t} \
      $n ${${n:#1}:+s} ${${l:#0}:+● $l live}
  done
}

# Branches of repo $1 that could get a new worktree, most recent first:
# local and origin/* (deduped), minus the ones already checked out
_lazyspace_branches() {
  local ref e
  local -A skip
  _lazyspace_worktrees $1
  for e in $reply; do skip[${${e#*$'\t'}%$'\t'*}]=1; done
  for ref in ${(f)"$(git -C $1 for-each-ref --sort=-committerdate --format='%(refname)' refs/heads refs/remotes/origin)"}; do
    ref=${${ref#refs/heads/}#refs/remotes/origin/}
    [[ $ref == HEAD || -n $skip[$ref] ]] && continue
    skip[$ref]=1
    print -r -- $ref
  done
}

# Unregistered git repos (~-abbreviated) under the search= setting, else the
# usual project dirs in $HOME; the repo containing $PWD comes first
_lazyspace_findrepos() {
  local d depth
  local -a roots
  local -A skip
  _lazyspace_repos
  for d in $reply; do skip[$d]=1; done
  if _lazyspace_toplevel && [[ -z $skip[$REPLY] ]]; then
    skip[$REPLY]=1; print -r -- ${REPLY/#$HOME/\~}
  fi
  _lazyspace_setting search_depth LAZYSPACE_SEARCH_DEPTH 4; depth=$REPLY
  _lazyspace_setting search LAZYSPACE_SEARCH
  if [[ -n $REPLY ]]; then
    roots=(${~=REPLY}(N/))
  else
    roots=($HOME/{Projects,projects,code,src,dev,work,git,repos,workspace}(N/))
    (( $#roots )) || roots=($HOME)
  fi
  (( $#roots )) || return 0
  command find -L $roots -maxdepth $depth \
    \( -name .git -type d -print -prune \) -o \
    \( \( -name '.?*' -o -name node_modules -o -name vendor -o -name Library \) -prune \) 2>/dev/null |
    while read -r d; do
      d=${d%/.git}
      [[ -n $skip[$d] ]] && continue
      print -r -- ${d/#$HOME/\~}
    done
}

# Fuzzy-pick a line from stdin. REPLY=the pick, or the typed query when
# nothing matches or with ctrl-n. Args: label, prompt.
_lazyspace_pick() {
  local out
  local -a lines
  out=$(fzf --layout reverse --style full --print-query --no-sort \
    --border-label " $1 " --prompt "$2" \
    --header 'enter pick (or the typed name if nothing matches)   ctrl-n use typed name   esc cancel' \
    --bind 'ctrl-n:print-query')
  (( $? == 130 || $? == 2 )) && return 1
  lines=("${(@f)out}")
  REPLY=${lines[2]:-$lines[1]}
  [[ -n $REPLY ]]
}

# One row per tmux window: "t<TAB>=session:index<TAB>display"; ● marks the
# window an attached client is looking at
_lazyspace_winrows() {
  local line ws=0 wn=0 wc=0 i
  local -a f S N C P M keyed
  # by session name, then window number
  for line in ${(f)"$(_lazyspace_tmux list-windows -a -F $'#{session_name}\t#{window_index}:#{window_name}\t#{pane_current_command}\t#{pane_current_path}\t#{?#{&&:#{window_active},#{session_attached}},●,}' 2>/dev/null)"}; do
    f=("${(@ps:\t:)line}")
    keyed+=("${f[1]:l}"$'\0'"${(l:6::0:)${f[2]%%:*}}"$'\0'"$line")
  done
  for line in ${${(o)keyed}#*$'\0'*$'\0'}; do
    f=("${(@ps:\t:)line}")
    S+=($f[1]); N+=($f[2]); C+=($f[3]); P+=(${f[4]/#$HOME/\~}); M+=("$f[5]")
    (( $#f[1] > ws )) && ws=$#f[1]
    (( $#f[2] > wn )) && wn=$#f[2]
    (( $#f[3] > wc )) && wc=$#f[3]
  done
  for (( i = 1; i <= $#S; i++ )); do
    printf 't\t=%s:%s\t\e[34m%-*s\e[0m  %-*s  \e[33m%-*s\e[0m  %s \e[32m%s\e[0m\n' \
      $S[i] ${N[i]%%:*} $ws $S[i] $wn $N[i] $wc $C[i] $P[i] "$M[i]"
  done
}

_lazyspace_names() {
  local repo e
  local -a repos
  _lazyspace_repos; repos=($reply)
  for repo in $repos; do
    _lazyspace_worktrees $repo
    for e in $reply; do
      _lazyspace_session $repo ${e%%$'\t'*} ${e##*$'\t'}
      print -r -- $REPLY
    done
  done
}

_lazyspace_preview() {
  local kind=$1 p=$2 e
  if [[ -z $p ]]; then
    [[ $FZF_LIST_LABEL == *Windows* ]] && print 'No tmux windows.' || print 'No repos yet — press a to add one.'
    return
  fi
  if [[ $kind == t ]]; then
    local -a out
    print -r -- $'\e[1m'${p#=}$'\e[0m  '"$(_lazyspace_tmux display-message -p -t $p '#{pane_current_command}  #{pane_current_path}')"
    print
    # the pane's last screenful, without its trailing blank lines
    out=("${(@f)$(_lazyspace_tmux capture-pane -ep -t $p)}")
    local n=$(( ${FZF_PREVIEW_LINES:-40} - 2 ))
    (( $#out > n )) && out=(${out[-n,-1]})
    print -rl -- "${out[@]}"
    return
  fi
  if [[ $kind == r ]]; then
    print -r -- $'\e[1m'${p:t}$'\e[0m  '${p/#$HOME/\~}
    print
    for e in ${(f)"$(git -C $p worktree list)"}; do print -r -- ${e/#$HOME/\~}; done
    [[ -r $p/.lazyspace ]] && { print; print -r -- $'\e[1m.lazyspace\e[0m'; print -r -- "$(<$p/.lazyspace)" }
    return
  fi
  local s
  local m=0
  _lazyspace_toplevel $p && { [[ $p == ${REPLY:A} ]] && m=1; _lazyspace_session $REPLY $p $m }
  s=$REPLY
  print -r -- $'\e[1m'$s$'\e[0m  '${p/#$HOME/\~}
  local wins
  if wins=$(_lazyspace_tmux list-windows -t "=$s" -F '#I:#W' 2>/dev/null); then
    print -r -- $'\e[32m● session\e[0m  '${(j:  :)${(f)wins}}
  else
    print -r -- $'\e[2m○ no session\e[0m'
  fi
  print
  git -C $p -c color.status=always status -sb | head -n 30
  print
  git -C $p log --oneline --color=always -n 15
}

# --- commands ---------------------------------------------------------------

_lazyspace_add() {
  _lazyspace_toplevel ${1:-$PWD} || { _lazyspace_err "not a git repo: ${1:-$PWD}"; return 1 }
  local repo=$REPLY
  _lazyspace_repos
  if (( ! ${reply[(Ie)$repo]} )); then
    _lazyspace_regfile
    mkdir -p ${REPLY:h}
    print -r -- $repo >>$REPLY
  fi
  print -r -- $repo
}

_lazyspace_forget() {
  local r=$1
  if [[ -z $r ]]; then _lazyspace_toplevel || { _lazyspace_err 'usage: lazyspace forget <repo>'; return 1 }; r=$REPLY; fi
  _lazyspace_find_repo $r || { _lazyspace_err "unknown repo: $r"; return 1 }
  local repo=$REPLY
  _lazyspace_repos
  local -a keep=(${reply:#$repo})
  _lazyspace_regfile
  print -rl -- $keep >| $REPLY
}

_lazyspace_ls() {
  local k p d
  _lazyspace_rows -s -p | while IFS=$'\t' read -r k p d; do print -r -- "$d  $p"; done
}

# lazyspace new <branch> [-r repo] [-b base] [--no-open]
_lazyspace_new() {
  local -a o_r o_b o_n
  zparseopts -D -E -F r:=o_r b:=o_b -no-open=o_n || return 1
  local br=$1 repo base p
  [[ -n $br ]] || { _lazyspace_err 'usage: lazyspace new <branch> [-r repo] [-b base] [--no-open]'; return 1 }
  if (( $#o_r )); then
    _lazyspace_find_repo $o_r[2] || _lazyspace_toplevel $o_r[2] || { _lazyspace_err "unknown repo: $o_r[2]"; return 1 }
  else
    _lazyspace_toplevel || { _lazyspace_err 'not in a repo; pass -r <repo>'; return 1 }
  fi
  repo=$REPLY
  _lazyspace_add $repo >/dev/null
  _lazyspace_setting worktrees LAZYSPACE_WORKTREES ~/.lazyspace/worktrees
  p=${~REPLY}/${repo:t}/${br//\//-}
  [[ -e $p ]] && { _lazyspace_err "already exists: $p"; return 1 }
  if git -C $repo show-ref -q --verify refs/heads/$br; then
    git -C $repo worktree add -q $p $br
  elif git -C $repo show-ref -q --verify refs/remotes/origin/$br; then
    git -C $repo worktree add -q --track -b $br $p origin/$br
  else
    base=${o_b[2]:-$(git -C $repo symbolic-ref -q --short refs/remotes/origin/HEAD)}
    git -C $repo worktree add -q -b $br $p ${base:-HEAD}
  fi || return 1

  local f
  if _lazyspace_conf copy $p $repo; then
    for f in ${=REPLY}; do
      [[ -e $repo/$f ]] && mkdir -p $p/${f:h} && cp -R $repo/$f $p/$f
    done
  fi
  _lazyspace_ensure $p || return 1
  local s=$REPLY
  if _lazyspace_conf setup $p $repo; then
    _lazyspace_type "=${s}:" "$REPLY" ${s//\//-}.setup
  fi
  print -r -- $p
  (( $#o_n )) || _lazyspace_open_path $p
}

# lazyspace open [worktree] — no match falls back to the TUI with a query
_lazyspace_open() {
  if [[ -z $1 ]]; then
    local top
    top=$(git rev-parse --show-toplevel 2>/dev/null) && { _lazyspace_open_path $top; return }
    _lazyspace_ui
  elif _lazyspace_resolve $1; then
    _lazyspace_open_path $REPLY
  else
    _lazyspace_ui $1
  fi
}

# REPLY="locked by <owner>" / "locked (<reason>)" if worktree $1 is locked
# (e.g. by Supacode, which writes JSON with an owner); fails if it isn't
_lazyspace_locked() {
  local gd why
  gd=$(git -C $1 rev-parse --absolute-git-dir 2>/dev/null) && [[ -e $gd/locked ]] || return 1
  why=$(<$gd/locked)
  if [[ $why == *'"owner":"'* ]]; then
    REPLY="locked by ${${why#*\"owner\":\"}%%\"*}"
  else
    REPLY="locked${why:+ ($why)}"
  fi
}

# lazyspace rm [worktree] [-f] [-D] — -f also overrides a lock
_lazyspace_rm() {
  local -a o_f o_D rmf
  zparseopts -D -E -F f=o_f D=o_D || return 1
  local p repo br s force locked
  if [[ -n $1 ]]; then
    _lazyspace_resolve $1 || { _lazyspace_err "no unique worktree for '$1' ($REPLY matches)"; return 1 }
    p=$REPLY
  else
    p=$(git rev-parse --show-toplevel 2>/dev/null) || { _lazyspace_err 'usage: lazyspace rm <worktree>'; return 1 }
  fi
  _lazyspace_toplevel $p || { _lazyspace_err "not a git worktree: $p"; return 1 }
  repo=$REPLY
  [[ ${p:A} == ${repo:A} ]] && { _lazyspace_err "refusing to remove the main worktree: $p"; return 1 }
  (( $#o_f )) && force=1
  if _lazyspace_locked $p; then
    locked=1
    if [[ -z $force ]]; then
      [[ -t 0 ]] || { _lazyspace_err "$p is $REPLY (use -f)"; return 1 }
      print -rn -- "${p/#$HOME/~} is $REPLY. Remove anyway? [y/N] "
      read -q </dev/tty || { print; return 1 }
      print
      force=1
    fi
  fi
  if [[ -z $force && -n $(git -C $p status --porcelain 2>/dev/null) ]]; then
    [[ -t 0 ]] || { _lazyspace_err "$p has changes (use -f)"; return 1 }
    print -rn -- "${p/#$HOME/~} has uncommitted changes. Remove anyway? [y/N] "
    read -q </dev/tty || { print; return 1 }
    print
    force=1
  fi
  br=$(git -C $p branch --show-current)
  _lazyspace_session $repo $p 0; s=$REPLY
  # git wants --force twice for a locked worktree
  [[ -n $force ]] && rmf=(--force ${locked:+--force})
  git -C $repo worktree remove $rmf $p || return 1
  (( $#o_D )) && [[ -n $br ]] && git -C $repo branch -q -D $br
  # last: this may kill the shell we are running in
  _lazyspace_tmux kill-session -t "=$s" 2>/dev/null
  return 0
}

# lazyspace run [worktree] — (re)start the .lazyspace run= command in window "run"
_lazyspace_run() {
  local p repo cmd s
  if [[ -n $1 ]]; then
    _lazyspace_resolve $1 || { _lazyspace_err "no unique worktree for '$1'"; return 1 }
    p=$REPLY
  else
    p=$(git rev-parse --show-toplevel 2>/dev/null) || { _lazyspace_err 'not in a worktree'; return 1 }
  fi
  _lazyspace_toplevel $p; repo=$REPLY
  _lazyspace_conf run $p $repo || { _lazyspace_err "no run= for ${repo:t} in .lazyspace or ~/.config/lazyspace/config"; return 1 }
  cmd=$REPLY
  _lazyspace_ensure $p || return 1
  s=$REPLY
  if (( ${${(f)"$(_lazyspace_tmux list-windows -t "=$s" -F '#W')"}[(Ie)run]} )); then
    _lazyspace_tmux respawn-window -k -c $p -t "=${s}:run"
  else
    _lazyspace_tmux new-window -d -n run -c $p -t "=${s}:"
  fi
  _lazyspace_type "=${s}:run" "$cmd" ${s//\//-}.run
}

# --- TUI --------------------------------------------------------------------

# fzf exits with an action ("open"/"new" + path); outside tmux we come back
# here when the attached session ends or is detached
# _lazyspace_ui [-w (start in the Windows view)] [query]
_lazyspace_ui() {
  local -a o_w
  zparseopts -D -E w=o_w
  local bin=${(q)LAZYSPACE_DIR}/bin/lazyspace k q=$1 out view=${o_w:+windows} rows sel i
  local -a binds lines start
  # coming back from a session, the first load puts the cursor on the row we
  # left (sel: its path or window target); this file hands that over once
  local -x LAZYSPACE_POSFILE=${TMPDIR:-/tmp}/lazyspace-$UID/pos.$$
  mkdir -p -m 700 ${LAZYSPACE_POSFILE:h}
  # start on the Windows view when tmux has any (unless given a query)
  [[ -z $view && -z $q && -n $(_lazyspace_tmux list-windows -a -F x 2>/dev/null) ]] && view=windows
  # Query changes emitted by a transform are ignored by fzf, so the
  # view-switching keys reset the input with directly chained actions.
  local reset="+clear-query+hide-input+rebind($_LAZYSPACE_LETTERS)"
  for k in / n d r a R q; do binds+=(--bind "${k}:transform:$bin _key {1} {2}"); done
  for k in enter tab esc w; do binds+=(--bind "${k}:transform($bin _key {1} {2})$reset"); done
  binds+=(--bind "load:transform:$bin _loaded")
  while :; do
    if [[ $view == windows ]]; then
      start=(--list-label ' Windows ' --footer "$_LAZYSPACE_FOOTER_WIN" --preview-window $_LAZYSPACE_PW_WIN)
    else
      start=(--list-label ' Worktrees · loading… ' --footer "$_LAZYSPACE_FOOTER_WT" --preview-window $_LAZYSPACE_PW)
    fi
    [[ -n $q ]] && start+=(--bind "start:show-input+unbind($_LAZYSPACE_LETTERS)")
    if [[ $view == windows ]]; then rows=$(_lazyspace_winrows); else rows=$(_lazyspace_rows); fi
    rm -f $LAZYSPACE_POSFILE
    if [[ -n $sel ]]; then
      lines=(${(f)rows})
      k=$'\t'  # $'\t' isn't expanded inside the subscript
      i=${lines[(i)*$k${(b)sel}$k*]}
      (( i <= $#lines )) && print $i >$LAZYSPACE_POSFILE
    fi
    out=$(print -r -- $rows |
      fzf --ansi --style full --layout reverse --no-input --no-sort \
      --delimiter '\t' --with-nth 3 --query "$q" \
      --border-label ' lazyspace ' --preview-label ' Details ' \
      --preview "$bin _preview {1} {2}" --pointer '▌' --gutter ' ' --info inline-right \
      --bind 'j:down,k:up' $start $binds) || return 0
    q= sel=
    lines=(${(f)out})
    case $lines[1] in
      (open) view= sel=$lines[2]; _lazyspace_open_path $sel || _lazyspace_pause ;;
      (new) view=; _lazyspace_ui_new $lines[2] || continue
            sel=$REPLY; _lazyspace_open_path $sel ;;
      (window) view=windows sel=$lines[2]; _lazyspace_open_window $sel || _lazyspace_pause ;;
      (*) rm -f $LAZYSPACE_POSFILE; return 0 ;;
    esac
    [[ -n $TMUX ]] && return 0
  done
}

# The Worktrees view loads in two steps, tracked in the list label: plain
# rows first ("· loading…"), then _lazyspace_loaded swaps in rows with git
# status ("· checking status…"). Worktrees view filtered to repo $1:
_lazyspace_wtload() {
  REPLY="change-list-label( Worktrees${1:+: $1} · loading… )+reload($bin _rows ${(q)1})"
}

# fzf load event: move to the row handed over in $LAZYSPACE_POSFILE (once),
# and after the plain worktree rows, fetch the ones with git status
_lazyspace_loaded() {
  local bin=${(q)LAZYSPACE_DIR}/bin/lazyspace lbl=${${FZF_LIST_LABEL# }% } base f
  local -a acts
  if [[ -n $LAZYSPACE_POSFILE && -s $LAZYSPACE_POSFILE ]]; then
    acts+=("pos($(<$LAZYSPACE_POSFILE))")
    rm -f $LAZYSPACE_POSFILE
  fi
  base=${lbl% · *}
  [[ $base == 'Worktrees: '* ]] && f=${base#Worktrees: }
  case $lbl in
    (Worktrees*' · loading…') acts+=("change-list-label( $base · checking status… )+reload-sync($bin _rows -s ${(q)f})") ;;
    (Worktrees*' · checking status…') acts+=("change-list-label( $base )") ;;
  esac
  (( $#acts )) && print -r -- ${(j:+:)acts}
}

# Key dispatcher: prints fzf actions. Args: row kind, row path.
_lazyspace_key() {
  local bin=${(q)LAZYSPACE_DIR}/bin/lazyspace kind=$1 p=$2 qp=${(q)2}
  local lbl=${${${FZF_LIST_LABEL# }% }% · *} rl foot=$_LAZYSPACE_FOOTER_WT out wt
  local win="change-list-label( Windows )+change-footer($_LAZYSPACE_FOOTER_WIN)+change-preview-window($_LAZYSPACE_PW_WIN)+reload($bin _winrows)+first"
  local pw="change-preview-window($_LAZYSPACE_PW)"
  _lazyspace_wtload; wt=$REPLY
  case $lbl in
    (Repos) rl="reload($bin _reporows)"; foot=$_LAZYSPACE_FOOTER_REPO ;;
    (Windows) rl="reload($bin _winrows)"; foot=$_LAZYSPACE_FOOTER_WIN ;;
    ('Worktrees: '*) _lazyspace_wtload ${lbl#Worktrees: }; rl=$REPLY ;;
    (*) rl=$wt ;;
  esac
  case $FZF_KEY in
    (/) print -r -- "show-input+unbind($_LAZYSPACE_LETTERS)" ;;
    (esc)
      [[ $FZF_INPUT_STATE == hidden ]] && print abort ;;
    (q) print abort ;;
    (R) print -r -- "$rl+change-footer($foot)" ;;
    (tab)
      case $lbl in
        (Repos) print -r -- $win ;;
        (Windows) print -r -- "change-footer($_LAZYSPACE_FOOTER_WT)+$pw+$wt+first" ;;
        (*) print -r -- "change-list-label( Repos )+change-footer($_LAZYSPACE_FOOTER_REPO)+reload($bin _reporows)+first" ;;
      esac ;;
    (w) print -r -- $win ;;
    (enter)
      [[ -n $p ]] || return 0
      if [[ $kind == r ]]; then
        _lazyspace_wtload ${p:t}
        print -r -- "change-footer($_LAZYSPACE_FOOTER_WT)+$REPLY+first"
      elif [[ $kind == t ]]; then
        print -r -- "become(printf '%s\\n' window $qp)"
      else
        print -r -- "become(printf '%s\\n' open $qp)"
      fi ;;
    (n) [[ $kind == t ]] || print -r -- "become(printf '%s\\n' new $qp)" ;;
    (a)
      # a filtered list would hide the new repo
      if [[ $lbl == Repos ]]; then print -r -- "execute($bin _ui_add)+$rl"
      else print -r -- "execute($bin _ui_add)+change-footer($_LAZYSPACE_FOOTER_WT)+$pw+$wt"; fi ;;
    (d)
      [[ -n $p ]] || return 0
      case $kind in
        (r) print -r -- "execute($bin _ui_forget $qp)+$rl" ;;
        (t) print -r -- "execute($bin _ui_killwin $qp)+$rl" ;;
        (*) print -r -- "execute($bin _ui_rm $qp)+$rl" ;;
      esac ;;
    (r)
      [[ $kind == w ]] || return 0
      if out=$(_lazyspace_run $p 2>&1); then print -r -- "$rl+change-footer($foot)"
      else print -r -- "change-footer( ${${out#lazyspace: }//[()]/} )"; fi ;;
  esac
}

# Prompt for a branch and create its worktree; REPLY=its path
_lazyspace_ui_new() {
  local repo br
  if ! { [[ -n $1 ]] && _lazyspace_toplevel $1 } && ! _lazyspace_toplevel; then
    print 'Add a repo first (a).'; _lazyspace_pause; return 1
  fi
  repo=$REPLY
  _lazyspace_branches $repo | _lazyspace_pick "New worktree in ${repo:t}" 'branch> ' || return 1
  br=$REPLY
  REPLY=$(_lazyspace_new --no-open -r $repo $br) || { _lazyspace_pause; return 1 }
}

_lazyspace_ui_add() {
  _lazyspace_findrepos | _lazyspace_pick 'Add repo' 'repo> ' || return 0
  _lazyspace_add ${REPLY/#\~/$HOME} >/dev/null || _lazyspace_pause
}

_lazyspace_ui_killwin() {
  print -rn -- "Kill window ${1#=}? [y/N] "
  read -q </dev/tty && _lazyspace_tmux kill-window -t "$1"
  print
}

_lazyspace_ui_forget() {
  print -n "Forget ${1:t}? (files are kept) [y/N] "
  read -q </dev/tty && _lazyspace_forget $1
  print
}

# REPLY=warning when branch $2 (seen from worktree $1) has commits that no
# remote has (as of the last fetch), else empty
_lazyspace_unpushed() {
  local n s
  n=$(git -C $1 rev-list --count refs/heads/$2 --not --remotes 2>/dev/null) || n=0
  REPLY=
  (( n )) || return 0
  (( n == 1 )) && s="1 commit" || s="$n commits"
  if git -C $1 show-ref -q --verify refs/remotes/origin/$2; then
    REPLY="$s on $2 aren't on origin; deleting the branch drops them"
  else
    REPLY="$2 was never pushed; deleting it drops its $s"
  fi
  REPLY+=" (git reflog can still find them for a while)"
}

_lazyspace_ui_rm() {
  local br repo
  if _lazyspace_toplevel $1 && [[ ${1:A} == ${REPLY:A} ]]; then
    repo=$REPLY
    print -rn -- "${1/#$HOME/~} is the repo itself, not a removable worktree. Forget ${repo:t} instead? (files are kept) [y/N] "
    read -q </dev/tty && _lazyspace_forget $repo
    print
    return
  fi
  br=$(git -C $1 branch --show-current 2>/dev/null)
  print -rn -- "Remove worktree ${1/#$HOME/~}? [y/N] "
  read -q </dev/tty || { print; return }
  print
  local -a flags
  if [[ -n $br ]]; then
    _lazyspace_unpushed $1 $br
    [[ -n $REPLY ]] && print -r -- $'\e[33mWarning:\e[0m '$REPLY
    print -rn -- "Also delete local branch $br? (the remote is untouched) [y/N] "
    read -q </dev/tty && flags+=(-D)
    print
  fi
  _lazyspace_rm $flags $1 || _lazyspace_pause
}

_lazyspace_help() {
  cat <<'EOF'
lazyspace — git worktrees, each in its own tmux session

  lazyspace                      open the TUI
  lazyspace add [path]           register a repo
  lazyspace forget [repo]        unregister a repo
  lazyspace repos                list registered repos
  lazyspace ls                   list worktrees with status
  lazyspace new <branch> [-r repo] [-b base] [--no-open]
                                 create a worktree (+ .lazyspace copy/setup) and open it
  lazyspace open [worktree]      attach/switch to a worktree's session
  lazyspace rm [worktree] [-f] [-D]
                                 remove a worktree (-f: even if dirty or locked,
                                 -D: delete its local branch too)
  lazyspace run [worktree]       (re)start the .lazyspace run= command in window "run"
  lazyspace windows              open the TUI on all tmux windows (enter switches)

.lazyspace (repo root, key=value; indent lines to continue a value):
  setup=…  run=…  copy=file1 file2
~/.config/lazyspace/config: the same keys under [repo-name] or [/path/to/repo];
  at the top, before any section: search=dirs  search_depth=n  worktrees=dir
EOF
}

lazyspace() {
  emulate -L zsh
  local cmd=$1
  (( $# )) && shift
  case $cmd in
    # run the TUI from disk: its key bindings call bin/lazyspace, so a shell
    # that sourced an older version would otherwise mix old and new code
    ('') $LAZYSPACE_DIR/bin/lazyspace _ui ;;
    (add|forget|new|open|rm|run|ls) _lazyspace_$cmd "$@" ;;
    (windows) $LAZYSPACE_DIR/bin/lazyspace _ui -w ;;
    (repos) _lazyspace_repos; print -rl -- $reply ;;
    (help|-h|--help) _lazyspace_help ;;
    (_*) _lazyspace$cmd "$@" ;;
    (*) _lazyspace_err "unknown command: $cmd"; _lazyspace_help >&2; return 1 ;;
  esac
}

# Completion. After compinit, autoload by absolute path and keep our dir off
# fpath: an exported FPATH leaks into every session's shell, where compinit
# would audit (and possibly reject) this directory.
if (( $+functions[compdef] )); then
  fpath=(${fpath:#$LAZYSPACE_DIR})
  autoload -Uz $LAZYSPACE_DIR/_lazyspace
  compdef _lazyspace lazyspace
else
  fpath+=($LAZYSPACE_DIR)
fi
