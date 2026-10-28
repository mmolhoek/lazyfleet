# lazyfleet: The TUI: the fzf driver and its key dispatcher, hand-off to other tools, and the prompts behind the keys.
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.

# keys that type into the find input instead while it's shown
typeset -g _LAZYFLEET_LETTERS='j,k,n,d,p,e,g,o,O,r,a,w,c,C,R,q,/'
typeset -g _LAZYFLEET_FOOTER_WT=$'↵ open  (n)ew worktree  (a)dd project
(d)elete  (p)ull  (e)ditor  (g) lazygit
(o)pen PR  (O) new PR
(w)indows  ⇥ windows  / find
(c) project config  (C) global settings
(r)eload  (q)uit'
typeset -g _LAZYFLEET_FOOTER_WIN=$'↵ switch  (d) kill
⇥ worktrees  / find
(r)eload  (q)uit
(C) global settings'
# list/Details split: the Windows view is mostly preview
typeset -g _LAZYFLEET_PW='right,50%' _LAZYFLEET_PW_WIN='right,70%'

# --- TUI --------------------------------------------------------------------

# fzf exits with an action ("open"/"new" + path); outside tmux we come back
# here when the attached session ends or is detached
# _lazyfleet_ui [-w (start in the Windows view)] [query]
_lazyfleet_ui() {
  local -a o_w
  zparseopts -D -E w=o_w
  local bin=${(q)LAZYFLEET_DIR}/bin/lazyfleet k q=$1 out view=${o_w:+windows} rows sel i rc
  local -a binds lines start
  # coming back from a session, the first load puts the cursor on the row we
  # left (sel: its path or window target); this file hands that over once
  _lazyfleet_footers
  _lazyfleet_ui_label; local label=$REPLY
  _lazyfleet_tmpdir || return 1
  local -x LAZYFLEET_POSFILE=$REPLY/pos.$$
  # background jobs (pull) send fzf actions here; unix socket paths are
  # limited to 103 bytes; without it p pulls in the foreground
  local sock=$REPLY/fzf.$$.sock
  (( $#sock < 104 )) && binds+=(--listen=$sock) || sock=
  # start on the Windows view when tmux has any (unless given a query)
  [[ -z $view && -z $q && -n $(_lazyfleet_tmux list-windows -a -F x 2>/dev/null) ]] && view=windows
  # Query changes emitted by a transform are ignored by fzf, so the
  # view-switching keys reset the input with directly chained actions.
  local reset="+clear-query+hide-input+rebind($_LAZYFLEET_LETTERS)"
  for k in / n d p e g o O r a c C R q; do binds+=(--bind "${k}:transform:$bin _key {1} {2}"); done
  for k in enter tab esc w; do binds+=(--bind "${k}:transform($bin _key {1} {2})$reset"); done
  binds+=(--bind "load:transform:$bin _loaded")
  while :; do
    if [[ $view == windows ]]; then
      start=(--list-label ' Windows ' --footer "$_LAZYFLEET_FOOTER_WIN" --preview-window $_LAZYFLEET_PW_WIN)
    else
      start=(--list-label ' Worktrees · loading… ' --footer "$_LAZYFLEET_FOOTER_WT" --preview-window $_LAZYFLEET_PW)
    fi
    [[ -n $q ]] && start+=(--bind "start:show-input+unbind($_LAZYFLEET_LETTERS)")
    if [[ $view == windows ]]; then rows=$(_lazyfleet_winrows); else rows=$(_lazyfleet_rows); fi
    rm -f $LAZYFLEET_POSFILE
    if [[ -n $sel ]]; then
      lines=(${(f)rows})
      k=$'\t'  # $'\t' isn't expanded inside the subscript
      i=${lines[(i)*$k${(b)sel}$k*]}
      (( i <= $#lines )) && print $i >$LAZYFLEET_POSFILE
    fi
    out=$(print -r -- $rows |
      fzf --ansi --style full --layout reverse --no-input --no-sort \
      --delimiter '\t' --with-nth 3 --query "$q" \
      --border-label "$label" --preview-label ' Details ' \
      --with-shell "${commands[zsh]:-/bin/zsh} -c" \
      --preview "$bin _preview -f {1} {2}" --pointer '▌' --gutter ' ' --info inline-right \
      --bind 'j:down,k:up' $start $binds)
    rc=$?
    [[ -n $sock ]] && rm -f $sock
    (( rc )) && return 0
    q= sel=
    lines=(${(f)out})
    case $lines[1] in
      (open) view= sel=$lines[2]; _lazyfleet_open_path $sel || _lazyfleet_pause ;;
      (new) view=; _lazyfleet_ui_new $lines[2] || continue
            sel=$REPLY; _lazyfleet_open_path $sel ;;
      (edit|lazygit) view= sel=$lines[2]; _lazyfleet_handoff $lines[1] $sel || _lazyfleet_pause ;;
      (window) view=windows sel=$lines[2]; _lazyfleet_open_window $sel || _lazyfleet_pause ;;
      (*) rm -f $LAZYFLEET_POSFILE; return 0 ;;
    esac
    [[ -n $TMUX ]] && return 0
  done
}

# The Worktrees view loads in two steps, tracked in the list label: plain
# rows first ("· loading…"), then _lazyfleet_loaded swaps in rows with git
# status ("· checking status…"). Repo names and paths never go into the
# action text itself (a ")" in one would end the action and could add
# others): fzf hands them over through {2} and $FZF_LIST_LABEL.
_lazyfleet_wtload() {
  REPLY="change-list-label( Worktrees · loading… )+reload($bin _rows)"
}

# Print the Worktrees list label for stage $1 (loading, checking, done)
_lazyfleet_wtlabel() {
  local stage
  case $1 in
    (loading) stage=' · loading…' ;;
    (checking) stage=' · checking status…' ;;
  esac
  print -r -- " Worktrees$stage "
}

# fzf load event: move to the row handed over in $LAZYFLEET_POSFILE (once),
# and after the plain worktree rows, fetch the ones with git status
_lazyfleet_loaded() {
  local bin=${(q)LAZYFLEET_DIR}/bin/lazyfleet lbl=${${FZF_LIST_LABEL# }% }
  local -a acts
  if [[ -n $LAZYFLEET_POSFILE && -s $LAZYFLEET_POSFILE ]]; then
    acts+=("pos($(<$LAZYFLEET_POSFILE))")
    rm -f $LAZYFLEET_POSFILE
  fi
  case $lbl in
    (Worktrees*' · loading…') acts+=("transform-list-label($bin _wtlabel checking)+reload-sync($bin _rows -s)") ;;
    (Worktrees*' · checking status…') acts+=("transform-list-label($bin _wtlabel done)") ;;
  esac
  (( $#acts )) && print -r -- ${(j:+:)acts}
}

# Key dispatcher: prints fzf actions. Args: row kind, row path.
_lazyfleet_key() {
  _lazyfleet_footers
  # the row's path is passed on as {2}, never as text in the actions
  local bin=${(q)LAZYFLEET_DIR}/bin/lazyfleet kind=$1 p=$2
  local lbl=${${${FZF_LIST_LABEL# }% }% · *} rl foot=$_LAZYFLEET_FOOTER_WT out wt
  local win="change-list-label( Windows )+change-footer($_LAZYFLEET_FOOTER_WIN)+change-preview-window($_LAZYFLEET_PW_WIN)+reload($bin _winrows)+first"
  local pw="change-preview-window($_LAZYFLEET_PW)"
  _lazyfleet_wtload; wt=$REPLY
  case $lbl in
    (Windows) rl="reload($bin _winrows)"; foot=$_LAZYFLEET_FOOTER_WIN ;;
    (*) rl=$wt ;;
  esac
  case $FZF_KEY in
    (/) print -r -- "show-input+unbind($_LAZYFLEET_LETTERS)" ;;
    (esc)
      [[ $FZF_INPUT_STATE == hidden ]] && print abort ;;
    (q) print abort ;;
    (c)
      # the row's project; the Windows view has none, so the settings
      if [[ $kind == w && -n $p ]]; then print -r -- "execute($bin config {2})+$rl"
      else print -r -- "execute($bin config)+$rl"; fi ;;
    (C) print -r -- "execute($bin config)+$rl" ;;
    (r|R) print -r -- "$rl+change-footer($foot)" ;;
    (tab)
      case $lbl in
        (Windows) print -r -- "change-footer($_LAZYFLEET_FOOTER_WT)+$pw+$wt+first" ;;
        (*) print -r -- $win ;;
      esac ;;
    (w) print -r -- $win ;;
    (enter)
      [[ -n $p ]] || return 0
      if [[ $kind == t ]]; then
        print -r -- "become(printf '%s\\n' window {2})"
      else
        print -r -- "become(printf '%s\\n' open {2})"
      fi ;;
    (n) [[ $kind == t ]] || print -r -- "become(printf '%s\\n' new {2})" ;;
    (a) print -r -- "execute($bin _ui_add)+change-footer($_LAZYFLEET_FOOTER_WT)+$pw+$wt" ;;
    (d)
      [[ -n $p ]] || return 0
      case $kind in
        (t) print -r -- "execute($bin _ui_killwin {2})+$rl" ;;
        (*) print -r -- "execute($bin _ui_rm {2})+$rl" ;;
      esac ;;
    (e|g)
      # the editor or lazygit, in a window of the worktree's session
      [[ $kind == w && -n $p ]] || return 0
      [[ $FZF_KEY == e ]] && print -r -- "become(printf '%s\\n' edit {2})" || print -r -- "become(printf '%s\\n' lazygit {2})" ;;
    (o)
      [[ $kind == w && -n $p ]] || return 0
      print -r -- "execute($bin _ui_openpr {2})" ;;
    (O)
      # GitHub's page for a new pull request of the worktree's branch
      [[ $kind == w && -n $p ]] || return 0
      print -r -- "execute($bin _ui_newpr {2})" ;;
    (p)
      [[ $kind == w && -n $p ]] || return 0
      # in the background when fzf listens: the row shows ⟳ until it's done
      if [[ -n $FZF_SOCK ]]; then print -r -- "execute-silent($bin _ui_pull {2})+$rl"
      else print -r -- "execute($bin _ui_pull {2})+$rl"; fi ;;
  esac
}

# --- hand-off: other tools, in the worktree ---------------------------------
# The editor and lazygit run in a window of the worktree's own session (named
# "edit" and "lazygit"), which is created once and shown again when it exists.

# REPLY=the command line to run in the worktree for tool $1 (edit|lazygit)
_lazyfleet_tool() {
  emulate -L zsh
  local ed
  case $1 in
    (edit)
      ed=${VISUAL:-${EDITOR:-vi}}
      (( $+commands[${ed%% *}] )) || [[ ${ed%% *} == */* && -x ${ed%% *} ]] ||
        { _lazyfleet_err "editor '${ed%% *}' not found (set \$VISUAL or \$EDITOR)"; return 1 }
      REPLY="$ed ." ;;
    (lazygit)
      (( $+commands[lazygit] )) ||
        { _lazyfleet_err "lazygit is not installed (https://github.com/jesseduffield/lazygit)"; return 1 }
      REPLY=lazygit ;;
    (*) _lazyfleet_err "unknown tool: $1"; return 1 ;;
  esac
}

# Show tool $1 (edit|lazygit) for worktree $2: in its window, started when
# there is none, then switch to it (inside tmux) or attach (outside)
_lazyfleet_handoff() {
  emulate -L zsh
  local tool=$1 p=$2 cmd s id= line sep='@@lf@@'
  _lazyfleet_tool $tool || return 1
  cmd=$REPLY
  _lazyfleet_ensure $p || return 1
  s=$REPLY
  for line in ${(f)"$(_lazyfleet_tmux list-windows -t "=$s" -F "#{window_name}${sep}#{window_id}" 2>/dev/null)"}; do
    if [[ ${line%%$sep*} == $tool ]]; then id=${line##*$sep}; break; fi
  done
  if [[ -z $id ]]; then
    id=$(_lazyfleet_tmux new-window -d -P -F '#{window_id}' -t "=$s:" -c ${p:A} -n $tool "exec $cmd") ||
      { _lazyfleet_err "could not start $tool in session $s"; return 1 }
    # a tool that cannot start ends its window at once: give it a moment, so
    # that we can say so instead of switching to nothing
    zmodload zsh/zselect 2>/dev/null && zselect -t 20
  fi
  _lazyfleet_tmux select-window -t $id 2>/dev/null ||
    { _lazyfleet_err "$tool ended right away; run '${cmd% .}' in ${p/#$HOME/~} to see why"; return 1 }
  _lazyfleet_attach "=$s"
}

# Open URL $1 in a browser: $BROWSER, else the system's opener
_lazyfleet_browser() {
  emulate -L zsh
  if [[ -n $BROWSER ]]; then
    command ${=BROWSER} $1
  elif [[ $OSTYPE == darwin* ]] && (( $+commands[open] )); then
    command open $1 &>/dev/null
  elif (( $+commands[xdg-open] )); then
    command xdg-open $1 &>/dev/null
  else
    _lazyfleet_err "no browser found (set \$BROWSER)"; return 1
  fi
}

# Open the pull request of worktree $1 in the browser, from what the pull
# request marks know (so it needs the same: gh, a GitHub origin, pr_status on).
_lazyfleet_openpr() {
  emulate -L zsh
  local p=$1 repo slug br url
  local -A prs
  local -a f
  _lazyfleet_toplevel $p && repo=$REPLY || { _lazyfleet_err "not a git worktree: $p"; return 1 }
  _lazyfleet_need_branch $p || return 1
  br=$REPLY
  if _lazyfleet_pr_enabled && _lazyfleet_ghslug $repo; then
    slug=$REPLY
  else
    _lazyfleet_err "pull requests need gh, a GitHub origin, and pr_status on"; return 1
  fi
  _lazyfleet_pr_read $slug >/dev/null ||
    { _lazyfleet_err "no pull request data yet (it is fetched in the background): try again in a moment"; return 1 }
  f=("${(@ps:\t:)prs[${slug:l}:$br]}")
  url=$f[4]
  [[ -n $url ]] || { _lazyfleet_err "no pull request known for $br"; return 1 }
  # the cache is data, and this goes to a program: only GitHub pull request links
  [[ $url =~ '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$' ]] ||
    { _lazyfleet_err "not a GitHub pull request link: ${url//[[:cntrl:]]/ }"; return 1 }
  _lazyfleet_browser $url
}

_lazyfleet_ui_openpr() { _lazyfleet_openpr $1 || _lazyfleet_pause }

# REPLY=$1 percent-encoded for a URL path (byte by byte, so it does not depend on the locale)
_lazyfleet_urlencode() {
  emulate -L zsh
  local c bytes out=
  # (s::) makes one empty element of an empty string, which would encode as %
  for c in ${(s::)1}; do
    if [[ $c == [A-Za-z0-9._~/-] ]]; then
      out+=$c
    else
      bytes=$(print -rn -- $c | od -An -v -tx1)
      out+=${(U)${(j::)${(@)${=bytes}/#/%}}}
    fi
  done
  REPLY=$out
}

# Open GitHub's "create pull request" page for the branch of worktree $1 in the
# browser. Nothing is created here: the title and the description are written
# on the page.
_lazyfleet_newpr() {
  emulate -L zsh
  local p=$1 repo slug br def url
  _lazyfleet_toplevel $p && repo=$REPLY || { _lazyfleet_err "not a git worktree: $p"; return 1 }
  _lazyfleet_need_branch $p || return 1
  br=$REPLY
  _lazyfleet_ghslug $repo && slug=$REPLY ||
    { _lazyfleet_err "a pull request needs a GitHub origin"; return 1 }
  def=$(git -C $repo symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
  [[ $br != ${def#origin/} ]] ||
    { _lazyfleet_err "$br is the default branch: there is nothing to open a pull request from"; return 1 }
  git -C $repo show-ref --verify -q "refs/remotes/origin/$br" ||
    { _lazyfleet_err "$br is not on origin yet: run 'git push -u origin $br' first"; return 1 }
  _lazyfleet_urlencode $br
  url="https://github.com/$slug/compare/$REPLY?expand=1"
  _lazyfleet_browser $url
}

_lazyfleet_ui_newpr() { _lazyfleet_newpr "$@" || _lazyfleet_pause }

# Prompt for a branch and create its worktree; REPLY=its path
_lazyfleet_ui_new() {
  local repo br
  if ! { [[ -n $1 ]] && _lazyfleet_toplevel $1 } && ! _lazyfleet_toplevel; then
    print 'Add a repo first (a).'; _lazyfleet_pause; return 1
  fi
  repo=$REPLY
  _lazyfleet_branches $repo | _lazyfleet_pick "New worktree in ${repo:t}" 'branch> ' || return 1
  br=$REPLY
  REPLY=$(_lazyfleet_new -q --no-open -r $repo $br) || { _lazyfleet_pause; return 1 }
}

_lazyfleet_ui_add() {
  _lazyfleet_findrepos | _lazyfleet_pick 'Add repo' 'repo> ' || return 0
  _lazyfleet_add ${REPLY/#\~/$HOME} >/dev/null || _lazyfleet_pause
}

_lazyfleet_ui_killwin() {
  _lazyfleet_ask "Kill window ${1#=}?" && _lazyfleet_tmux kill-window -t "$1"
}

# REPLY=warning when branch $2 (seen from worktree $1) has commits that no
# remote has (as of the last fetch), else empty
_lazyfleet_unpushed() {
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

# Pull worktree $1; with $FZF_SOCK in a detached job that marks the row as
# pulling, then has fzf reload (and show git's output if it failed)
_lazyfleet_ui_pull() {
  [[ -n $FZF_SOCK ]] || { _lazyfleet_pull $1 || _lazyfleet_pause; return }
  _lazyfleet_pulldir || return 1
  local m=$REPLY/${1//\//%} bin=${(q)LAZYFLEET_DIR}/bin/lazyfleet
  [[ -e $m ]] && return 0  # already pulling
  : >$m
  {
    local out
    out=$(_lazyfleet_pull $1 2>&1) || print -r -- $out >$m.err
    rm -f $m
    _lazyfleet_fzfpost "transform($bin _pulled)"
  } </dev/null >/dev/null 2>&1 &!
}

# fzf actions once a background pull is done: show failed pulls, then reload
_lazyfleet_pulled() {
  local bin=${(q)LAZYFLEET_DIR}/bin/lazyfleet
  _lazyfleet_pulldir || return
  local -a errs=($REPLY/*.err(N))
  (( $#errs )) && print -rn -- "execute($bin _ui_pullfail)+"
  FZF_KEY=r _lazyfleet_key
}

_lazyfleet_ui_pullfail() {
  local e
  _lazyfleet_pulldir || return
  for e in $REPLY/*.err(N); do print -r -- "$(<$e)"; print; rm -f $e; done
  _lazyfleet_pause
}

_lazyfleet_ui_rm() {
  local br repo
  if _lazyfleet_toplevel $1 && [[ ${1:A} == ${REPLY:A} ]]; then
    repo=$REPLY
    _lazyfleet_ask "${1/#$HOME/~} is the repo itself, not a removable worktree. Forget ${repo:t} instead? (files are kept)" &&
      _lazyfleet_forget $repo
    return
  fi
  _lazyfleet_branch_of $1; br=$REPLY
  _lazyfleet_ask "Remove worktree ${1/#$HOME/~}?" || return
  local -a flags ids
  local e
  _lazyfleet_containers_in $1
  if (( $#reply )); then
    print -r -- $'\e[33mWarning:\e[0m '"$#reply Docker container(s) from this worktree are running; their files can't be deleted until they stop:"
    for e in $reply; do e=${e#*$'\t'}; print -r -- "   ${e%%$'\t'*}"; ids+=(${e##*$'\t'}); done
    if _lazyfleet_ask "Stop them?"; then
      _lazyfleet_step "Stopping $#ids container(s)"
      docker stop $ids >/dev/null
      _lazyfleet_done || _lazyfleet_pause
    fi
  fi
  if [[ -n $br ]]; then
    _lazyfleet_unpushed $1 $br
    [[ -n $REPLY ]] && print -r -- $'\e[33mWarning:\e[0m '$REPLY
    _lazyfleet_ask "Also delete local branch $br? (the remote is untouched)" && flags+=(-D)
  fi
  _lazyfleet_rm $flags $1 || _lazyfleet_pause
}

# REPLY=the TUI's border label, which points out an available update
_lazyfleet_ui_label() {
  if _lazyfleet_update_available; then REPLY=" lazyfleet · $REPLY available "
  else REPLY=' lazyfleet '; fi
}

# Put the version line under each TUI footer. The footers are globals that the
# TUI and its key handler (a separate process) both use, so both call this;
# doing it twice in one process changes nothing.
typeset -g _LAZYFLEET_FOOTERS_DONE=
_lazyfleet_footers() {
  [[ -n $_LAZYFLEET_FOOTERS_DONE ]] && return 0
  _LAZYFLEET_FOOTERS_DONE=1
  _lazyfleet_version_line || return 0
  _LAZYFLEET_FOOTER_WT+=$'\n'$REPLY
  _LAZYFLEET_FOOTER_WIN+=$'\n'$REPLY
}

_lazyfleet_interactive() { [[ -t 1 && -t 2 ]] }

# The TUI, plus the update check when run by a person: refresh the cache before
# it starts, and print the notice after it ends, when it would not be wiped
_lazyfleet_ui_checked() {
  local rc
  _lazyfleet_interactive && _lazyfleet_update_refresh
  _lazyfleet_ui "$@"; rc=$?
  _lazyfleet_interactive && _lazyfleet_update_notice
  return $rc
}
