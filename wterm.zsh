# wterm — a minimal Supacode: git worktrees, each with its own tmux session.
# Source this file from .zshrc, then run `wterm` (TUI) or `wterm help`.

typeset -g WTERM_DIR=${${(%):-%x}:A:h}
typeset -g _WTERM_LETTERS='j,k,n,d,r,a,R,q'
typeset -g _WTERM_FOOTER_WT=$'↵ open   n new   d delete   r run
⇥ repos  / find  R reload   q quit'
typeset -g _WTERM_FOOTER_REPO=$'↵ worktrees   n new   a add   d forget
⇥ worktrees   / find  R reload  q quit'

# --- plumbing ---------------------------------------------------------------

_wterm_tmux() { command ${=WTERM_TMUX:-tmux} "$@" }

_wterm_err() { print -ru2 -- "wterm: $*"; return 1 }

_wterm_pause() { print -n 'press any key '; read -sk1 </dev/tty; print }

_wterm_regfile() { REPLY=${XDG_CONFIG_HOME:-$HOME/.config}/wterm/repos }

# reply=(registered repo paths)
_wterm_repos() {
  _wterm_regfile
  reply=()
  [[ -r $REPLY ]] && reply=(${(f)"$(<$REPLY)"})
}

# REPLY=main worktree of the repo containing $1 (default $PWD)
_wterm_toplevel() {
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
_wterm_find_repo() {
  local r
  _wterm_repos
  for r in $reply; do
    [[ ${r:t} == $1 || $r == ${1:A} ]] && { REPLY=$r; return 0 }
  done
  return 1
}

# REPLY=branch name from a HEAD file
_wterm_head() {
  local h=$(<$1)
  [[ $h == 'ref: refs/heads/'* ]] && REPLY=${h#ref: refs/heads/} || REPLY='(detached)'
}

# reply=("path<TAB>branch<TAB>ismain" ...) for repo $1
_wterm_worktrees() {
  local g=$1/.git d wt line br m skip i=0
  reply=()
  if [[ -d $g ]]; then
    # read .git directly: no fork
    _wterm_head $g/HEAD; reply+=("$1"$'\t'"$REPLY"$'\t'1)
    for d in $g/worktrees/*(N/); do
      [[ -r $d/gitdir ]] || continue
      wt=$(<$d/gitdir); wt=${wt%/.git}
      [[ $wt == /* ]] || wt=${${d}/$wt:A}
      [[ -d $wt ]] || continue
      _wterm_head $d/HEAD; reply+=("$wt"$'\t'"$REPLY"$'\t'0)
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
_wterm_session() {
  REPLY=${1:t}
  [[ $3 == 1 ]] || REPLY+=/${2:t}
  REPLY=${REPLY//[.:]/-}
}

# REPLY=value of key $1 from the first .wterm found in dirs $2..
_wterm_conf() {
  local key=$1 dir line
  shift
  for dir; do
    [[ -r $dir/.wterm ]] || continue
    for line in ${(f)"$(<$dir/.wterm)"}; do
      [[ $line == $key=* ]] && { REPLY=${line#$key=}; return 0 }
    done
  done
  REPLY=
  return 1
}

# REPLY=worktree path for a path, session name, branch or dir name
_wterm_resolve() {
  [[ -d $1 ]] && { REPLY=${1:A}; return 0 }
  local repo e p br
  local -a repos hits
  _wterm_repos; repos=($reply)
  for repo in $repos; do
    _wterm_worktrees $repo
    for e in $reply; do
      p=${e%%$'\t'*}; br=${${e#*$'\t'}%$'\t'*}
      _wterm_session $repo $p ${e##*$'\t'}
      [[ $1 == $REPLY || $1 == $br || $1 == ${repo:t}/$br || $1 == ${p:t} ]] && hits+=($p)
    done
  done
  hits=(${(u)hits})
  (( $#hits == 1 )) && { REPLY=$hits[1]; return 0 }
  REPLY=$#hits
  return 1
}

# Create the worktree's session (detached) if needed; REPLY=session name
_wterm_ensure() {
  local p=${1:A} repo m=0
  _wterm_toplevel $p || { _wterm_err "not a git worktree: $p"; return 1 }
  repo=$REPLY
  [[ $p == ${repo:A} ]] && m=1
  _wterm_session $repo $p $m
  _wterm_tmux has-session -t "=$REPLY" 2>/dev/null ||
    _wterm_tmux new-session -d -s $REPLY -c $p
}

_wterm_open_path() {
  _wterm_ensure $1 || return
  if [[ -n $TMUX ]]; then
    _wterm_tmux switch-client -t "=$REPLY"
  else
    # tmux refuses a stdin named /dev/tty (as under fzf's become), so attach
    # through the real controlling terminal device, opened read-write: the
    # server draws through the client's stdin, a read-only fd stays blank
    local t=${$(ps -o tty= -p $$ 2>/dev/null)// /}
    if [[ -c /dev/$t ]]; then
      _wterm_tmux attach-session -t "=$REPLY" <>/dev/$t
    else
      _wterm_tmux attach-session -t "=$REPLY"
    fi
  fi
}

# "* ↑1 ↓2" for worktree $1
_wterm_wtstatus() {
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

# _wterm_rows [-s (with git status)] [-p (plain)] [repo name filter]
_wterm_rows() {
  setopt local_options no_monitor no_notify
  local -a o_s o_p
  zparseopts -D -E s=o_s p=o_p
  local only=$1 repo e p s i tmp wn=0 wb=0
  local c_repo=$'\e[34m' c_live=$'\e[32m' c_st=$'\e[33m' c_off=$'\e[0m'
  (( $#o_p )) && c_repo= c_live= c_st= c_off=
  local -A live
  local -a repos paths names branches lives stats
  for s in ${(f)"$(_wterm_tmux list-sessions -F '#S' 2>/dev/null)"}; do live[$s]=1; done
  _wterm_repos; repos=($reply)
  for repo in $repos; do
    [[ -n $only && ${repo:t} != $only ]] && continue
    _wterm_worktrees $repo
    for e in $reply; do
      p=${e%%$'\t'*}
      _wterm_session $repo $p ${e##*$'\t'}
      paths+=($p); names+=(${repo:t}); branches+=(${${e#*$'\t'}%$'\t'*})
      lives+=("${live[$REPLY]:+●}"); stats+=('')
      (( $#names[-1] > wn )) && wn=$#names[-1]
      (( $#branches[-1] > wb )) && wb=$#branches[-1]
    done
  done
  if (( $#o_s && $#paths )); then
    tmp=${TMPDIR:-/tmp}/wterm.$$.$RANDOM
    mkdir -p $tmp
    for i in {1..$#paths}; do _wterm_wtstatus $paths[i] >$tmp/$i & done
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

_wterm_reporows() {
  local repo s n l wn=0
  local -a repos sessions
  sessions=(${(f)"$(_wterm_tmux list-sessions -F '#S' 2>/dev/null)"})
  _wterm_repos; repos=($reply)
  for repo in $repos; do (( $#repo:t > wn )) && wn=$#repo:t; done
  for repo in $repos; do
    _wterm_worktrees $repo; n=$#reply
    l=0
    for s in $sessions; do [[ $s == ${repo:t} || $s == ${repo:t}/* ]] && (( l++ )); done
    printf 'r\t%s\t\e[34m%-*s\e[0m  %d worktree%s  \e[32m%s\e[0m\n' $repo $wn ${repo:t} \
      $n ${${n:#1}:+s} ${${l:#0}:+● $l live}
  done
}

_wterm_names() {
  local repo e
  local -a repos
  _wterm_repos; repos=($reply)
  for repo in $repos; do
    _wterm_worktrees $repo
    for e in $reply; do
      _wterm_session $repo ${e%%$'\t'*} ${e##*$'\t'}
      print -r -- $REPLY
    done
  done
}

_wterm_preview() {
  local kind=$1 p=$2 e
  [[ -n $p ]] || { print 'No repos yet — press a to add one.'; return }
  if [[ $kind == r ]]; then
    print -r -- $'\e[1m'${p:t}$'\e[0m  '${p/#$HOME/\~}
    print
    for e in ${(f)"$(git -C $p worktree list)"}; do print -r -- ${e/#$HOME/\~}; done
    [[ -r $p/.wterm ]] && { print; print -r -- $'\e[1m.wterm\e[0m'; print -r -- "$(<$p/.wterm)" }
    return
  fi
  local s
  local m=0
  _wterm_toplevel $p && { [[ $p == ${REPLY:A} ]] && m=1; _wterm_session $REPLY $p $m }
  s=$REPLY
  print -r -- $'\e[1m'$s$'\e[0m  '${p/#$HOME/\~}
  local wins
  if wins=$(_wterm_tmux list-windows -t "=$s" -F '#I:#W' 2>/dev/null); then
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

_wterm_add() {
  _wterm_toplevel ${1:-$PWD} || { _wterm_err "not a git repo: ${1:-$PWD}"; return 1 }
  local repo=$REPLY
  _wterm_repos
  if (( ! ${reply[(Ie)$repo]} )); then
    _wterm_regfile
    mkdir -p ${REPLY:h}
    print -r -- $repo >>$REPLY
  fi
  print -r -- $repo
}

_wterm_forget() {
  local r=$1
  if [[ -z $r ]]; then _wterm_toplevel || { _wterm_err 'usage: wterm forget <repo>'; return 1 }; r=$REPLY; fi
  _wterm_find_repo $r || { _wterm_err "unknown repo: $r"; return 1 }
  local repo=$REPLY
  _wterm_repos
  local -a keep=(${reply:#$repo})
  _wterm_regfile
  print -rl -- $keep >| $REPLY
}

_wterm_ls() {
  local k p d
  _wterm_rows -s -p | while IFS=$'\t' read -r k p d; do print -r -- "$d  $p"; done
}

# wterm new <branch> [-r repo] [-b base] [--no-open]
_wterm_new() {
  local -a o_r o_b o_n
  zparseopts -D -E -F r:=o_r b:=o_b -no-open=o_n || return 1
  local br=$1 repo base p
  [[ -n $br ]] || { _wterm_err 'usage: wterm new <branch> [-r repo] [-b base] [--no-open]'; return 1 }
  if (( $#o_r )); then
    _wterm_find_repo $o_r[2] || _wterm_toplevel $o_r[2] || { _wterm_err "unknown repo: $o_r[2]"; return 1 }
  else
    _wterm_toplevel || { _wterm_err 'not in a repo; pass -r <repo>'; return 1 }
  fi
  repo=$REPLY
  _wterm_add $repo >/dev/null
  p=${WTERM_WORKTREES:-$HOME/.wterm/worktrees}/${repo:t}/${br//\//-}
  [[ -e $p ]] && { _wterm_err "already exists: $p"; return 1 }
  if git -C $repo show-ref -q --verify refs/heads/$br; then
    git -C $repo worktree add -q $p $br
  elif git -C $repo show-ref -q --verify refs/remotes/origin/$br; then
    git -C $repo worktree add -q --track -b $br $p origin/$br
  else
    base=${o_b[2]:-$(git -C $repo symbolic-ref -q --short refs/remotes/origin/HEAD)}
    git -C $repo worktree add -q -b $br $p ${base:-HEAD}
  fi || return 1

  local f
  if _wterm_conf copy $p $repo; then
    for f in ${=REPLY}; do
      [[ -e $repo/$f ]] && mkdir -p $p/${f:h} && cp -R $repo/$f $p/$f
    done
  fi
  _wterm_ensure $p || return 1
  local s=$REPLY
  if _wterm_conf setup $p $repo; then
    _wterm_tmux send-keys -t "=${s}:" -l -- "$REPLY" \; send-keys -t "=${s}:" Enter
  fi
  print -r -- $p
  (( $#o_n )) || _wterm_open_path $p
}

# wterm open [worktree] — no match falls back to the TUI with a query
_wterm_open() {
  if [[ -z $1 ]]; then
    local top
    top=$(git rev-parse --show-toplevel 2>/dev/null) && { _wterm_open_path $top; return }
    _wterm_ui
  elif _wterm_resolve $1; then
    _wterm_open_path $REPLY
  else
    _wterm_ui $1
  fi
}

# wterm rm [worktree] [-f] [-D]
_wterm_rm() {
  local -a o_f o_D
  zparseopts -D -E -F f=o_f D=o_D || return 1
  local p repo br s force
  if [[ -n $1 ]]; then
    _wterm_resolve $1 || { _wterm_err "no unique worktree for '$1' ($REPLY matches)"; return 1 }
    p=$REPLY
  else
    p=$(git rev-parse --show-toplevel 2>/dev/null) || { _wterm_err 'usage: wterm rm <worktree>'; return 1 }
  fi
  _wterm_toplevel $p || { _wterm_err "not a git worktree: $p"; return 1 }
  repo=$REPLY
  [[ ${p:A} == ${repo:A} ]] && { _wterm_err "refusing to remove the main worktree: $p"; return 1 }
  (( $#o_f )) && force=1
  if [[ -z $force && -n $(git -C $p status --porcelain 2>/dev/null) ]]; then
    [[ -t 0 ]] || { _wterm_err "$p has changes (use -f)"; return 1 }
    print -n "$p has uncommitted changes. Remove anyway? [y/N] "
    read -q </dev/tty || { print; return 1 }
    print
    force=1
  fi
  br=$(git -C $p branch --show-current)
  _wterm_session $repo $p 0; s=$REPLY
  git -C $repo worktree remove ${force:+--force} $p || return 1
  (( $#o_D )) && [[ -n $br ]] && git -C $repo branch -q -D $br
  # last: this may kill the shell we are running in
  _wterm_tmux kill-session -t "=$s" 2>/dev/null
  return 0
}

# wterm run [worktree] — (re)start the .wterm run= command in window "run"
_wterm_run() {
  local p repo cmd s
  if [[ -n $1 ]]; then
    _wterm_resolve $1 || { _wterm_err "no unique worktree for '$1'"; return 1 }
    p=$REPLY
  else
    p=$(git rev-parse --show-toplevel 2>/dev/null) || { _wterm_err 'not in a worktree'; return 1 }
  fi
  _wterm_toplevel $p; repo=$REPLY
  _wterm_conf run $p $repo || { _wterm_err "no run= in .wterm of ${repo:t}"; return 1 }
  cmd=$REPLY
  _wterm_ensure $p || return 1
  s=$REPLY
  if (( ${${(f)"$(_wterm_tmux list-windows -t "=$s" -F '#W')"}[(Ie)run]} )); then
    _wterm_tmux respawn-window -k -c $p -t "=${s}:run"
  else
    _wterm_tmux new-window -d -n run -c $p -t "=${s}:"
  fi
  _wterm_tmux send-keys -t "=${s}:run" -l -- "$cmd" \; send-keys -t "=${s}:run" Enter
}

# --- TUI --------------------------------------------------------------------

_wterm_ui() {
  local bin=${(q)WTERM_DIR}/bin/wterm k
  local -a binds
  # Query changes emitted by a transform are ignored by fzf, so the
  # view-switching keys reset the input with directly chained actions.
  local reset="+clear-query+hide-input+rebind($_WTERM_LETTERS)"
  for k in / n d r a R q; do binds+=(--bind "${k}:transform:$bin _key {1} {2}"); done
  for k in enter tab esc; do binds+=(--bind "${k}:transform($bin _key {1} {2})$reset"); done
  _wterm_rows | fzf --ansi --style full --layout reverse --no-input --no-sort \
    --delimiter '\t' --with-nth 3 --query "$1" \
    --border-label ' wterm ' --list-label ' Worktrees ' --preview-label ' Details ' \
    --preview "$bin _preview {1} {2}" --preview-window 'right,55%' \
    --footer "$_WTERM_FOOTER_WT" --pointer '▌' --gutter ' ' --info inline-right \
    --bind "start:reload($bin _rows -s)${1:++show-input+unbind($_WTERM_LETTERS)}" \
    --bind 'j:down,k:up' $binds
}

# Key dispatcher: prints fzf actions. Args: row kind, row path.
_wterm_key() {
  local bin=${(q)WTERM_DIR}/bin/wterm kind=$1 p=$2 qp=${(q)2}
  local lbl=${${FZF_LIST_LABEL# }% } rl foot=$_WTERM_FOOTER_WT out
  case $lbl in
    (Repos) rl="reload($bin _reporows)"; foot=$_WTERM_FOOTER_REPO ;;
    ('Worktrees: '*) rl="reload($bin _rows -s ${(q)lbl#Worktrees: })" ;;
    (*) rl="reload($bin _rows -s)" ;;
  esac
  case $FZF_KEY in
    (/) print -r -- "show-input+unbind($_WTERM_LETTERS)" ;;
    (esc)
      [[ $FZF_INPUT_STATE == hidden ]] && print abort ;;
    (q) print abort ;;
    (R) print -r -- "$rl+change-footer($foot)" ;;
    (tab)
      if [[ $lbl == Repos ]]; then
        print -r -- "change-list-label( Worktrees )+change-footer($_WTERM_FOOTER_WT)+reload($bin _rows -s)+first"
      else
        print -r -- "change-list-label( Repos )+change-footer($_WTERM_FOOTER_REPO)+reload($bin _reporows)+first"
      fi ;;
    (enter)
      [[ -n $p ]] || return 0
      if [[ $kind == r ]]; then
        print -r -- "change-list-label( Worktrees: ${p:t} )+change-footer($_WTERM_FOOTER_WT)+reload($bin _rows -s ${(q)p:t})+first"
      else
        print -r -- "become($bin open $qp)"
      fi ;;
    (n) print -r -- "become($bin _ui_new $qp)" ;;
    (a) print -r -- "execute($bin _ui_add)+$rl" ;;
    (d)
      [[ -n $p ]] || return 0
      if [[ $kind == r ]]; then print -r -- "execute($bin _ui_forget $qp)+$rl"
      else print -r -- "execute($bin _ui_rm $qp)+$rl"; fi ;;
    (r)
      [[ $kind == w ]] || return 0
      if out=$(_wterm_run $p 2>&1); then print -r -- "$rl+change-footer($foot)"
      else print -r -- "change-footer( ${${out#wterm: }//[()]/} )"; fi ;;
  esac
}

_wterm_ui_new() {
  local repo br
  if ! { [[ -n $1 ]] && _wterm_toplevel $1 } && ! _wterm_toplevel; then
    print 'Add a repo first (a).'; _wterm_pause; _wterm_ui; return
  fi
  repo=$REPLY
  print -n "New worktree in ${repo:t}, branch: "
  read -r br </dev/tty
  [[ -n $br ]] || { _wterm_ui; return }
  _wterm_new -r $repo $br >/dev/null || { _wterm_pause; _wterm_ui }
}

_wterm_ui_add() {
  local p
  print -n "Add repo [$PWD]: "
  read -r p </dev/tty
  p=${p/#\~/$HOME}
  _wterm_add ${p:-$PWD} >/dev/null || _wterm_pause
}

_wterm_ui_forget() {
  print -n "Forget ${1:t}? (files are kept) [y/N] "
  read -q </dev/tty && _wterm_forget $1
  print
}

_wterm_ui_rm() {
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
  _wterm_rm $flags $1 || _wterm_pause
}

_wterm_help() {
  cat <<'EOF'
wterm — git worktrees, each in its own tmux session

  wterm                      open the TUI
  wterm add [path]           register a repo
  wterm forget [repo]        unregister a repo
  wterm repos                list registered repos
  wterm ls                   list worktrees with status
  wterm new <branch> [-r repo] [-b base] [--no-open]
                             create a worktree (+ .wterm copy/setup) and open it
  wterm open [worktree]      attach/switch to a worktree's session
  wterm rm [worktree] [-f] [-D]
                             remove a worktree (-D: delete its branch too)
  wterm run [worktree]       (re)start the .wterm run= command in window "run"

.wterm (repo root, key=value):  setup=…  run=…  copy=file1 file2
EOF
}

wterm() {
  emulate -L zsh
  local cmd=$1
  (( $# )) && shift
  case $cmd in
    ('') _wterm_ui ;;
    (add|forget|new|open|rm|run|ls) _wterm_$cmd "$@" ;;
    (repos) _wterm_repos; print -rl -- $reply ;;
    (help|-h|--help) _wterm_help ;;
    (_*) _wterm$cmd "$@" ;;
    (*) _wterm_err "unknown command: $cmd"; _wterm_help >&2; return 1 ;;
  esac
}

fpath+=($WTERM_DIR)
if (( $+functions[compdef] )); then
  autoload -Uz _wterm
  compdef _wterm wterm
fi
