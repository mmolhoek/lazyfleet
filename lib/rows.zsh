# lazyfleet: What the TUI lists and previews: worktree and window rows, repo discovery, and the picker.
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.

# _lazyfleet_rows [-s (with git status)] [-p (plain)] [repo name filter]
_lazyfleet_rows() {
  setopt local_options no_monitor no_notify
  local -a o_s o_p
  zparseopts -D -E s=o_s p=o_p
  local only=$1 repo e p s i tmp wn=0 wb=0 line d
  local c_repo=$'\e[34m' c_live=$'\e[32m' c_st=$'\e[33m' c_dk=$'\e[36m' c_off=$'\e[0m'
  (( $#o_p )) && c_repo= c_live= c_st= c_dk= c_off=
  local -A live dk agtally prs
  local -a repos paths names branches lives stats docks sess pslugs rbr kicks fl
  local pr_on= pslug pv prm star br
  for s in ${(f)"$(_lazyfleet_tmux list-sessions -F '#S' 2>/dev/null)"}; do live[$s]=1; done
  _lazyfleet_pr_enabled && pr_on=1
  _lazyfleet_repos; repos=($reply)
  for repo in $repos; do
    [[ -n $only && ${repo:t} != $only ]] && continue
    _lazyfleet_worktrees $repo
    pslug= rbr=()
    if [[ -n $pr_on ]] && _lazyfleet_ghslug $repo; then
      pslug=$REPLY
      _lazyfleet_pr_read $pslug
    fi
    for e in $reply; do
      _lazyfleet_wt_path $e; p=$REPLY
      _lazyfleet_wt_branch $e; br=$REPLY
      _lazyfleet_wt_ismain $e
      _lazyfleet_session $repo $p $REPLY
      paths+=($p); names+=(${repo:t}); branches+=($br)
      lives+=("${live[$REPLY]:+●}"); stats+=(''); docks+=(''); sess+=($REPLY)
      pslugs+=($pslug); rbr+=($branches[-1])
      (( $#names[-1] > wn )) && wn=$#names[-1]
      (( $#branches[-1] > wb )) && wb=$#branches[-1]
    done
    [[ -n $pslug ]] && kicks+=($pslug "${(j: :)rbr}")
  done
  # out of date pull request data is refreshed in the background
  (( $#o_s && $#kicks )) && _lazyfleet_pr_kick $kicks
  _lazyfleet_agent_icons_on && _lazyfleet_agent_tally
  if (( $#o_s && $#paths )); then
    _lazyfleet_tmpdir || return 1
    tmp=$REPLY/status.$$.$RANDOM
    mkdir -m 700 $tmp || return 1
    for i in {1..$#paths}; do _lazyfleet_wtstatus $paths[i] >$tmp/$i & done
    { _lazyfleet_containers; print -rl -- $reply >$tmp/docker } &
    wait
    for i in {1..$#paths}; do stats[i]=$(<$tmp/$i); done
    for line in ${(f)"$(<$tmp/docker)"}; do
      d=${${line%%$'\t'*}:A}; dk[$d]=$(( ${dk[$d]:-0} + 1 ))
    done
    for i in {1..$#paths}; do docks[i]=${dk[${paths[i]:A}]:+🐳${dk[${paths[i]:A}]}}; done
    rm -rf $tmp
  fi
  _lazyfleet_pulldir
  for (( i = 1; i <= $#paths; i++ )); do
    # the * (uncommitted changes) goes last on the row, after the marks
    star=
    if [[ $stats[i] == '*'* ]]; then star=1; stats[i]=${${stats[i]#\*}# }; fi
    [[ -e $REPLY/${paths[i]//\//%} ]] && stats[i]="⟳ pulling${stats[i]:+ $stats[i]}"
    prm=
    if [[ -n $pslugs[i] ]]; then
      pv=${prs[${pslugs[i]:l}:${branches[i]}]}
      if [[ -n $pv ]]; then
        fl=("${(@ps:\t:)pv}")
        _lazyfleet_pr_mark $fl[1] $fl[2] $fl[3] ${o_p:+-p} && prm=$REPLY
      fi
    fi
    _lazyfleet_agent_marks_at $sess[i] ${o_p:+-p}
    printf 'w\t%s\t%s%-*s%s  %-*s  %s%1s%s %s%s%s%s%s%s%s%s%s%s%s\n' $paths[i] \
      "$c_repo" $wn $names[i] "$c_off" $wb $branches[i] \
      "$c_live" "$lives[i]" "$c_off" "$c_st" "$stats[i]" "$c_off" \
      "$c_dk" "${docks[i]:+${stats[i]:+ }$docks[i]}" "$c_off" "${prm:+ $prm}" "${REPLY:+ $REPLY}" \
      "${star:+ $c_st}" "${star:+*}" "${star:+$c_off}"
  done
}

# Branches of repo $1 that could get a new worktree, most recent first:
# local and origin/* (deduped), minus the ones already checked out
_lazyfleet_branches() {
  local ref e
  local -A skip
  _lazyfleet_worktrees $1
  for e in $reply; do _lazyfleet_wt_branch $e; skip[$REPLY]=1; done
  for ref in ${(f)"$(git -C $1 for-each-ref --sort=-committerdate --format='%(refname)' refs/heads refs/remotes/origin)"}; do
    ref=${${ref#refs/heads/}#refs/remotes/origin/}
    [[ $ref == HEAD || -n $skip[$ref] ]] && continue
    skip[$ref]=1
    print -r -- $ref
  done
}

# Unregistered git repos (~-abbreviated) under the search= setting, else the
# usual project dirs in $HOME; the repo containing $PWD comes first
_lazyfleet_findrepos() {
  local d depth
  local -a roots
  local -A skip
  _lazyfleet_repos
  for d in $reply; do skip[$d]=1; done
  if _lazyfleet_toplevel && [[ -z $skip[$REPLY] ]]; then
    skip[$REPLY]=1; print -r -- ${REPLY/#$HOME/\~}
  fi
  _lazyfleet_setting search_depth LAZYFLEET_SEARCH_DEPTH 4; depth=$REPLY
  _lazyfleet_setting search LAZYFLEET_SEARCH
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
_lazyfleet_pick() {
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
_lazyfleet_winrows() {
  emulate -L zsh
  setopt extended_glob
  local line ws=0 wn=0 wc=0 i k pad w green=$'\e[32m' off=$'\e[0m'
  # tmux >= 3.4 turns control characters (tabs) in -F output into "_" unless
  # it writes to a terminal, so use a printable ASCII separator (safe in any
  # locale) and turn it into tabs
  local sep='@@lf@@'
  local -a f S N C P M I W keyed
  local -A agtally
  # by session name, then window number
  for line in ${(f)"$(_lazyfleet_tmux list-windows -a -F "#{session_name}${sep}#{window_index}:#{window_name}${sep}#{pane_current_command}${sep}#{pane_current_path}${sep}#{?#{&&:#{window_active},#{session_attached}},●,}" 2>/dev/null)"}; do
    line=${line//$sep/$'\t'}
    f=("${(@ps:\t:)line}")
    keyed+=("${f[1]:l}"$'\0'"${(l:6::0:)${f[2]%%:*}}"$'\0'"$line")
  done
  for line in ${${(o)keyed}#*$'\0'*$'\0'}; do
    f=("${(@ps:\t:)line}")
    S+=($f[1]); N+=($f[2]); C+=($f[3]); P+=(${f[4]/#$HOME/\~}); M+=("$f[5]")
    (( $#f[2] > wn )) && wn=$#f[2]
    (( $#f[3] > wc )) && wc=$#f[3]
  done
  _lazyfleet_agent_icons_on && _lazyfleet_agent_tally w
  # the status icons follow the session name directly; the other columns line
  # up after the widest name-and-icons
  for (( i = 1; i <= $#S; i++ )); do
    k=$S[i]:${N[i]%%:*}
    _lazyfleet_agent_marks_at $k
    I[i]="${M[i]:+$green$M[i]$off}${REPLY:+${M[i]:+ }$REPLY}"
    W[i]=${#${I[i]//$'\e'\[[0-9;]##m/}}
    w=$(( ${#S[i]} + (W[i] ? 1 : 0) + W[i] ))
    (( w > ws )) && ws=$w
  done
  for (( i = 1; i <= $#S; i++ )); do
    pad=$(( ws - ${#S[i]} - (W[i] ? 1 : 0) - W[i] ))
    printf 't\t=%s:%s\t\e[34m%s\e[0m%s%s  %-*s  \e[33m%-*s\e[0m  %s\n' \
      $S[i] ${N[i]%%:*} $S[i] "${I[i]:+ $I[i]}" "${(l:pad:)}" $wn $N[i] $wc $C[i] $P[i]
  done
}

_lazyfleet_names() {
  local repo e p
  local -a repos
  _lazyfleet_repos; repos=($reply)
  for repo in $repos; do
    _lazyfleet_worktrees $repo
    for e in $reply; do
      _lazyfleet_wt_path $e; p=$REPLY
      _lazyfleet_wt_ismain $e
      _lazyfleet_session $repo $p $REPLY
      print -r -- $REPLY
    done
  done
}

# Succeed when tmux pane $1 (an id like %3) is the pane lazyfleet itself runs
# in (tmux hands that to its children as $TMUX_PANE)
_lazyfleet_own_pane() { [[ -n $TMUX_PANE && $1 == $TMUX_PANE ]] }

# REPLY=preview of tmux window $1: a header line, then the pane's last
# screenful without its trailing blank lines; fails once the window is gone.
# For the window whose active pane is the one lazyfleet draws in, a note
# instead: a capture of it would contain this very preview, so every redraw
# would change what the next capture shows, and never settle.
_lazyfleet_winframe() {
  local head id
  local -a out
  # a gone window does not make display-message fail: it prints blanks, which
  # is why the pane id (never blank for a real pane) comes first
  head=$(_lazyfleet_tmux display-message -p -t $1 '#{pane_id} #{pane_current_command}  #{pane_current_path}' 2>/dev/null) || return 1
  id=${head%% *}; head=${head#* }
  [[ $id == %* ]] || return 1
  if _lazyfleet_own_pane $id; then
    REPLY=$'\e[1m'${1#=}$'\e[0m  '$head$'\n\n\e[2mlazyfleet is running here, so there is nothing to preview:\nthis screen would show up inside itself, over and over.\e[0m'
    return 0
  fi
  out=("${(@f)$(_lazyfleet_tmux capture-pane -ep -t $1)}")
  local n=$(( ${FZF_PREVIEW_LINES:-40} - 2 ))
  (( $#out > n )) && out=(${out[-n,-1]})
  REPLY=$'\e[1m'${1#=}$'\e[0m  '$head$'\n\n'${(F)out}
}

# Print the pull request of worktree $1's branch, if the cache knows one
_lazyfleet_pr_preview() {
  emulate -L zsh
  local -A prs
  local slug br pv age what title
  local -a fl
  _lazyfleet_pr_enabled || return 0
  _lazyfleet_ghslug $1 || return 0; slug=$REPLY
  _lazyfleet_branch_of $1 || return 0
  br=$REPLY
  _lazyfleet_pr_read $slug || return 0; age=$REPLY
  pv=$prs[${slug:l}:$br]
  [[ -n $pv ]] || return 0
  fl=("${(@ps:\t:)pv}")
  title=$fl[5]    # already free of control characters: _lazyfleet_pr_read strips them
  what=$fl[2]
  if [[ $fl[2] == (open|draft) ]]; then
    case $fl[3] in
      (pass) what+=' · checks passing' ;;
      (fail) what+=' · checks failing' ;;
      (pending) what+=' · checks running' ;;
      (*) what+=' · no checks' ;;
    esac
  fi
  print
  print -r -- $'\e[1mPR #'$fl[1]$'\e[0m  '$title
  print -r -- "   $what"$'  \e[2m'$fl[4]$'\e[0m'
  (( age > 600 )) && print -r -- $'   \e[2m(as of '$(( age / 60 ))$' min ago)\e[0m'
  return 0
}

# _lazyfleet_preview [-f] kind path — -f: a window preview keeps redrawing
# (when its pane changes) until fzf stops it for another row
_lazyfleet_preview() {
  local -a o_f
  zparseopts -D -E f=o_f
  local kind=$1 p=$2 e
  if [[ -z $p ]]; then
    [[ $FZF_LIST_LABEL == *Windows* ]] && print 'No tmux windows.' || print 'No repos yet — press a to add one.'
    return
  fi
  if [[ $kind == t ]]; then
    local last
    _lazyfleet_winframe $p || return
    print -r -- $REPLY
    (( $#o_f )) || return 0
    zmodload zsh/zselect
    last=$REPLY
    # no fork per tick: zselect -t sleeps (in 1/100 s) without a sleep process
    while zselect -t 50 || :; _lazyfleet_winframe $p; do
      [[ $REPLY == $last ]] && continue
      last=$REPLY
      print -rn -- $'\e[2J'; print -r -- $REPLY
    done
    return
  fi
  local s
  local m=0
  _lazyfleet_toplevel $p && { [[ $p == ${REPLY:A} ]] && m=1; _lazyfleet_session $REPLY $p $m }
  s=$REPLY
  print -r -- $'\e[1m'$s$'\e[0m  '${p/#$HOME/\~}
  local wins
  if wins=$(_lazyfleet_tmux list-windows -t "=$s" -F '#I:#W' 2>/dev/null); then
    print -r -- $'\e[32m● session\e[0m  '${(j:  :)${(f)wins}}
  else
    print -r -- $'\e[2m○ no session\e[0m'
  fi
  _lazyfleet_containers_in $p -c
  if (( $#reply )); then
    print -r -- $'\e[36m🐳 '$#reply' running\e[0m'
    for e in $reply[1,10]; do e=${e#*$'\t'}; print -r -- "   ${e%%$'\t'*}  "$'\e[2m'"${${e#*$'\t'}%%$'\t'*}"$'\e[0m'; done
    (( $#reply > 10 )) && print -r -- "   … $(( $#reply - 10 )) more"
  fi
  _lazyfleet_pr_preview $p
  print
  git -C $p --no-optional-locks -c color.status=always status -sb | head -n 30
  print
  git -C $p log --oneline --color=always -n 15
}
