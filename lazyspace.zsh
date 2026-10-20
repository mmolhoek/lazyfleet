# lazyspace — a minimal Supacode: git worktrees, each with its own tmux session.
# Source this file from .zshrc, then run `lazyspace` (TUI) or `lazyspace help`.

typeset -g LAZYSPACE_DIR=${${(%):-%x}:A:h}
typeset -g _LAZYSPACE_LETTERS='j,k,n,d,r,a,R,q'
typeset -g _LAZYSPACE_FOOTER_WT=$'↵ open  n new  a add  d del  r run
⇥ repos  / find  R reload   q quit'
typeset -g _LAZYSPACE_FOOTER_REPO=$'↵ worktrees   n new   a add   d forget
⇥ worktrees   / find  R reload  q quit'

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

# reply=(registered repo paths)
_lazyspace_repos() {
  _lazyspace_regfile
  reply=()
  [[ -r $REPLY ]] && reply=(${(f)"$(<$REPLY)"})
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

# reply=("path<TAB>branch<TAB>ismain" ...) for repo $1
_lazyspace_worktrees() {
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

# REPLY=value of key $2 in file $1. Indented lines after key= continue the
# value (minus the first one's indent). With repo $3, only [sections] naming
# that repo (by name or path) count.
_lazyspace_conf_read() {
  local key=$2 repo=$3 line sect ind on=1 hit=
  local -a val
  [[ -n $repo ]] && on=
  for line in "${(@f)$(<$1)}"; do
    if [[ -n $hit ]]; then
      if [[ -z $line || $line == [[:space:]]* ]]; then
        [[ -z $ind && $line == *[^[:space:]]* ]] && ind=${line%%[^[:space:]]*}
        val+=("${line#$ind}")
        continue
      fi
      break
    fi
    if [[ -n $repo && $line == '['*']' ]]; then
      sect=${${line#\[}%\]}; sect=${sect/#\~/$HOME}
      [[ $sect == ${repo:t} || ( $sect == */* && ${sect:A} == ${repo:A} ) ]] && on=1 || on=
    elif [[ -n $on && $line == $key=* ]]; then
      hit=1; val=("${line#$key=}")
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
  if [[ -n $TMUX ]]; then
    _lazyspace_tmux switch-client -t "=$REPLY"
  else
    # tmux refuses a stdin named /dev/tty (as under fzf's become), so attach
    # through the real controlling terminal device, opened read-write: the
    # server draws through the client's stdin, a read-only fd stays blank
    local t=${$(ps -o tty= -p $$ 2>/dev/null)// /}
    if [[ -c /dev/$t ]]; then
      _lazyspace_tmux attach-session -t "=$REPLY" <>/dev/$t
    else
      _lazyspace_tmux attach-session -t "=$REPLY"
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
  for i in {1..$#paths}; do
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
  [[ -n $p ]] || { print 'No repos yet — press a to add one.'; return }
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
  p=${LAZYSPACE_WORKTREES:-$HOME/.lazyspace/worktrees}/${repo:t}/${br//\//-}
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

# lazyspace rm [worktree] [-f] [-D]
_lazyspace_rm() {
  local -a o_f o_D
  zparseopts -D -E -F f=o_f D=o_D || return 1
  local p repo br s force
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
  if [[ -z $force && -n $(git -C $p status --porcelain 2>/dev/null) ]]; then
    [[ -t 0 ]] || { _lazyspace_err "$p has changes (use -f)"; return 1 }
    print -n "$p has uncommitted changes. Remove anyway? [y/N] "
    read -q </dev/tty || { print; return 1 }
    print
    force=1
  fi
  br=$(git -C $p branch --show-current)
  _lazyspace_session $repo $p 0; s=$REPLY
  git -C $repo worktree remove ${force:+--force} $p || return 1
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
_lazyspace_ui() {
  local bin=${(q)LAZYSPACE_DIR}/bin/lazyspace k q=$1 out
  local -a binds lines
  # Query changes emitted by a transform are ignored by fzf, so the
  # view-switching keys reset the input with directly chained actions.
  local reset="+clear-query+hide-input+rebind($_LAZYSPACE_LETTERS)"
  for k in / n d r a R q; do binds+=(--bind "${k}:transform:$bin _key {1} {2}"); done
  for k in enter tab esc; do binds+=(--bind "${k}:transform($bin _key {1} {2})$reset"); done
  while :; do
    out=$(_lazyspace_rows | fzf --ansi --style full --layout reverse --no-input --no-sort \
      --delimiter '\t' --with-nth 3 --query "$q" \
      --border-label ' lazyspace ' --list-label ' Worktrees ' --preview-label ' Details ' \
      --preview "$bin _preview {1} {2}" --preview-window 'right,55%' \
      --footer "$_LAZYSPACE_FOOTER_WT" --pointer '▌' --gutter ' ' --info inline-right \
      --bind "start:reload($bin _rows -s)${q:++show-input+unbind($_LAZYSPACE_LETTERS)}" \
      --bind 'j:down,k:up' $binds) || return 0
    q=
    lines=(${(f)out})
    case $lines[1] in
      (open) _lazyspace_open_path $lines[2] || _lazyspace_pause ;;
      (new) _lazyspace_ui_new $lines[2] || continue
            _lazyspace_open_path $REPLY ;;
      (*) return 0 ;;
    esac
    [[ -n $TMUX ]] && return 0
  done
}

# Key dispatcher: prints fzf actions. Args: row kind, row path.
_lazyspace_key() {
  local bin=${(q)LAZYSPACE_DIR}/bin/lazyspace kind=$1 p=$2 qp=${(q)2}
  local lbl=${${FZF_LIST_LABEL# }% } rl foot=$_LAZYSPACE_FOOTER_WT out
  case $lbl in
    (Repos) rl="reload($bin _reporows)"; foot=$_LAZYSPACE_FOOTER_REPO ;;
    ('Worktrees: '*) rl="reload($bin _rows -s ${(q)lbl#Worktrees: })" ;;
    (*) rl="reload($bin _rows -s)" ;;
  esac
  case $FZF_KEY in
    (/) print -r -- "show-input+unbind($_LAZYSPACE_LETTERS)" ;;
    (esc)
      [[ $FZF_INPUT_STATE == hidden ]] && print abort ;;
    (q) print abort ;;
    (R) print -r -- "$rl+change-footer($foot)" ;;
    (tab)
      if [[ $lbl == Repos ]]; then
        print -r -- "change-list-label( Worktrees )+change-footer($_LAZYSPACE_FOOTER_WT)+reload($bin _rows -s)+first"
      else
        print -r -- "change-list-label( Repos )+change-footer($_LAZYSPACE_FOOTER_REPO)+reload($bin _reporows)+first"
      fi ;;
    (enter)
      [[ -n $p ]] || return 0
      if [[ $kind == r ]]; then
        print -r -- "change-list-label( Worktrees: ${p:t} )+change-footer($_LAZYSPACE_FOOTER_WT)+reload($bin _rows -s ${(q)p:t})+first"
      else
        print -r -- "become(printf '%s\\n' open $qp)"
      fi ;;
    (n) print -r -- "become(printf '%s\\n' new $qp)" ;;
    (a)
      # a filtered list would hide the new repo
      if [[ $lbl == Repos ]]; then print -r -- "execute($bin _ui_add)+$rl"
      else print -r -- "execute($bin _ui_add)+change-list-label( Worktrees )+reload($bin _rows -s)"; fi ;;
    (d)
      [[ -n $p ]] || return 0
      if [[ $kind == r ]]; then print -r -- "execute($bin _ui_forget $qp)+$rl"
      else print -r -- "execute($bin _ui_rm $qp)+$rl"; fi ;;
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
  print -n "New worktree in ${repo:t}, branch: "
  read -r br </dev/tty
  [[ -n $br ]] || return 1
  REPLY=$(_lazyspace_new --no-open -r $repo $br) || { _lazyspace_pause; return 1 }
}

_lazyspace_ui_add() {
  local p
  print -n "Add repo [$PWD]: "
  read -r p </dev/tty
  p=${p/#\~/$HOME}
  _lazyspace_add ${p:-$PWD} >/dev/null || _lazyspace_pause
}

_lazyspace_ui_forget() {
  print -n "Forget ${1:t}? (files are kept) [y/N] "
  read -q </dev/tty && _lazyspace_forget $1
  print
}

_lazyspace_ui_rm() {
  local br
  br=$(git -C $1 branch --show-current 2>/dev/null)
  print -rn -- "Remove worktree ${1/#$HOME/\~}? [y/N] "
  read -q </dev/tty || { print; return }
  print
  local -a flags
  if [[ -n $br ]]; then
    print -n "Also delete branch $br? [y/N] "
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
                                 remove a worktree (-D: delete its branch too)
  lazyspace run [worktree]       (re)start the .lazyspace run= command in window "run"

.lazyspace (repo root, key=value; indent lines to continue a value):
  setup=…  run=…  copy=file1 file2
~/.config/lazyspace/config: the same keys under [repo-name] or [/path/to/repo]
EOF
}

lazyspace() {
  emulate -L zsh
  local cmd=$1
  (( $# )) && shift
  case $cmd in
    ('') _lazyspace_ui ;;
    (add|forget|new|open|rm|run|ls) _lazyspace_$cmd "$@" ;;
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
