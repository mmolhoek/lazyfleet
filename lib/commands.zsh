# lazyfleet: The commands: add, forget, ls, new, open, rm, pull and config.
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.

_lazyfleet_add() {
  _lazyfleet_toplevel ${1:-$PWD} || { _lazyfleet_err "not a git repo: ${1:-$PWD}"; return 1 }
  local repo=$REPLY r name
  _lazyfleet_repos
  # sessions (<repo>/...) and worktree dirs (<worktrees>/<repo>/...) are keyed
  # by the repo's name, so two registered repos can't share one — compared as
  # session names, where app.js and app-js are the same
  _lazyfleet_session $repo $repo 1; name=$REPLY
  for r in $reply; do
    _lazyfleet_session $r $r 1
    [[ $r != $repo && $REPLY == $name ]] &&
      { _lazyfleet_err "a repo named ${repo:t} is already registered: $r (lazyfleet forget it first)"; return 1 }
  done
  if (( ! ${reply[(Ie)$repo]} )); then
    _lazyfleet_regfile
    mkdir -p ${REPLY:h}
    print -r -- $repo >>$REPLY
  fi
  print -r -- $repo
}

_lazyfleet_forget() {
  local r=$1
  if [[ -z $r ]]; then _lazyfleet_toplevel || { _lazyfleet_err 'usage: lazyfleet forget <repo>'; return 1 }; r=$REPLY; fi
  _lazyfleet_find_repo $r || { _lazyfleet_err "unknown repo: $r"; return 1 }
  local repo=$REPLY
  _lazyfleet_repos
  local -a keep=(${reply:#$repo})
  _lazyfleet_regfile
  print -rl -- $keep >| $REPLY
}

_lazyfleet_ls() {
  local k p d
  _lazyfleet_rows -s -p | while IFS=$'\t' read -r k p d; do print -r -- "$d  $p"; done
}

# --- new --pr / new --issue --------------------------------------------------
# What GitHub says about a pull request or an issue is data, not instructions:
# the branch name is checked by git, and an issue's title only ever becomes
# [a-z0-9-] in a branch name.

# Common to both: REPLY=the repo's owner/name, after checking that the number
# is a number and that gh is there. Args: repo dir, number.
_lazyfleet_new_gh() {
  emulate -L zsh
  [[ $2 == <1-999999999> ]] || { _lazyfleet_err "not a number: ${2//[[:cntrl:]]/ }"; return 1 }
  (( $+commands[gh] )) || { _lazyfleet_err "this needs gh (https://cli.github.com), logged in"; return 1 }
  _lazyfleet_ghslug $1 || { _lazyfleet_err "this needs a GitHub remote called origin"; return 1 }
}

# REPLY=the branch to work on for pull request $2 of repo $1, fetched. A
# pull request from a fork has no branch here, so it gets a local branch pr-N.
_lazyfleet_new_from_pr() {
  emulate -L zsh
  local slug out ref head
  local -a f
  _lazyfleet_new_gh $1 $2 || return 1
  slug=$REPLY
  out=$(gh api repos/$slug/pulls/$2 --jq '[.head.ref, (.head.repo.full_name // "-")] | @tsv' 2>/dev/null) ||
    { _lazyfleet_err "could not read pull request #$2 of $slug (does it exist, and is gh logged in?)"; return 1 }
  f=("${(@ps:\t:)out}")
  ref=$f[1] head=$f[2]
  if [[ ${head:l} != ${slug:l} ]]; then
    # a fork, or a repository that is gone: GitHub keeps the commits as pull/N/head
    if ! git -C $1 show-ref -q --verify refs/heads/pr-$2; then
      git -C $1 fetch -q origin pull/$2/head:refs/heads/pr-$2 2>/dev/null ||
        { _lazyfleet_err "could not fetch pull request #$2"; return 1 }
    fi
    REPLY=pr-$2
    return 0
  fi
  # (a leading - is refused here too: the name goes to git fetch as an argument)
  [[ -n $ref && $ref != -* ]] && git check-ref-format --branch $ref >/dev/null 2>&1 ||
    { _lazyfleet_err "pull request #$2 has a branch name git does not accept"; return 1 }
  git -C $1 fetch -q origin $ref 2>/dev/null ||
    { _lazyfleet_err "could not fetch branch $ref of pull request #$2 (has it been deleted?)"; return 1 }
  REPLY=$ref
}

# REPLY=a branch name for issue $2 of repo $1: issue-<number>-<words of the title>
_lazyfleet_new_from_issue() {
  emulate -L zsh
  setopt extended_glob
  local slug out title name
  _lazyfleet_new_gh $1 $2 || return 1
  slug=$REPLY
  out=$(gh api repos/$slug/issues/$2 --jq '[.title, (.pull_request != null | tostring)] | @tsv' 2>/dev/null) ||
    { _lazyfleet_err "could not read issue #$2 of $slug (does it exist, and is gh logged in?)"; return 1 }
  [[ ${out##*$'\t'} == true ]] && { _lazyfleet_err "#$2 is a pull request: use --pr $2"; return 1 }
  title=${out%$'\t'*}
  name=${${${${title:l}//[^a-z0-9]##/-}#-}%-}
  name=${name[1,40]}; name=${name%-}
  REPLY=issue-$2${name:+-$name}
  # by construction a plain name; git has the last word
  git check-ref-format --branch $REPLY >/dev/null 2>&1 || { _lazyfleet_err "could not make a branch name for issue #$2"; return 1 }
}

# Say (like _lazyfleet_say) that the branch's .lazyfleet value for key $1 was
# passed over, if _lazyfleet_conf did that
_lazyfleet_say_ignored() {
  [[ $_lazyfleet_ignored == $1 ]] || return 0
  _lazyfleet_say "  ${(r:8:)1}skipped the branch's .lazyfleet value" "(it differs from the main worktree's; trust_branch_config=on uses it)"
}

# Is $1 a path inside the repo (relative, without a .. part)? Copy lists
# come from config files, which a branch can bring along.
_lazyfleet_inside() {
  [[ $1 != /* && $1 != (..|../*|*/..|*/../*) ]]
}

# Check out branch $2 of repo $1 as the new worktree $3, and start the summary
# (_lazyfleet_sum). A branch that does not exist yet starts from base $4, else
# origin/HEAD, else HEAD. $5 says where the branch came from, if it came from
# a pull request or an issue.
_lazyfleet_new_checkout() {
  local repo=$1 br=$2 p=$3 base=$4 src=$5 how
  typeset -ga _lazyfleet_sum=()
  if git -C $repo show-ref -q --verify refs/heads/$br; then
    how='existing local branch'
    git -C $repo worktree add -q $p $br
  elif git -C $repo show-ref -q --verify refs/remotes/origin/$br; then
    how="new, tracking origin/$br"
    git -C $repo worktree add -q --track -b $br $p origin/$br
  else
    base=${base:-$(git -C $repo symbolic-ref -q --short refs/remotes/origin/HEAD)}
    how="new, from ${base:-HEAD}"
    git -C $repo worktree add -q -b $br $p ${base:-HEAD}
  fi || return 1
  _lazyfleet_say "lazyfleet: new worktree ${p/#$HOME/~}"
  _lazyfleet_say "  branch  $br" "($how)"
  [[ -n $src ]] && _lazyfleet_say "  from    $src"
  return 0
}

# Copy what copy= lists from repo $1 into its new worktree $2, and say what was
# copied and what was not. Fails when a copy fails: setup may need the file.
_lazyfleet_new_copy() {
  local repo=$1 p=$2 f
  local -a copied skipped outside
  if _lazyfleet_conf copy $p $repo; then
    _lazyfleet_say_ignored copy
    for f in ${=REPLY}; do
      if ! _lazyfleet_inside $f; then
        outside+=($f)
      elif [[ -e $repo/$f ]]; then
        # setup may need these files: don't start it without them
        mkdir -p $p/${f:h} && cp -R $repo/$f $p/$f || {
          _lazyfleet_err "could not copy $f into ${p/#$HOME/~}; the worktree is there, but setup didn't run"
          return 1
        }
        copied+=($f)
      else
        skipped+=($f)
      fi
    done
    (( $#copied )) && _lazyfleet_say "  copy    $copied " "from ${repo/#$HOME/~} ($_lazyfleet_from)"
    for f in $skipped; do _lazyfleet_say "  ${(l:8:)}skipped $f: not in the main worktree"; done
    for f in $outside; do _lazyfleet_say "  ${(l:8:)}skipped $f: not a path inside the repo"; done
  else
    _lazyfleet_say "  copy   " "nothing (no copy= configured)"
    _lazyfleet_say_ignored copy
  fi
  return 0
}

# Run the setup= of repo $1 in the new worktree $2's session, which that
# creates; without one, just create the session. The summary so far goes with it.
_lazyfleet_new_setup() {
  local repo=$1 p=$2 s cmd f
  _lazyfleet_session $repo $p 0
  s=$REPLY
  # (an empty setup= is no setup: unquoted, an empty $cmd would vanish from the
  # arguments below and the summary's first line would run as the command)
  if _lazyfleet_conf setup $p $repo && [[ -n $REPLY ]]; then
    cmd=$REPLY
    _lazyfleet_say_ignored setup
    if [[ $cmd == *$'\n'* ]]; then
      _lazyfleet_say "  setup   ${#${(f)cmd}}-line script" "($_lazyfleet_from) → running in session $s:"
      for f in ${(f)cmd}; do _lazyfleet_say "          " "$f"; done
    else
      _lazyfleet_say "  setup   $cmd " "($_lazyfleet_from) → running in session $s"
    fi
    _lazyfleet_setup_run $s $p "$cmd" $_lazyfleet_sum
  else
    _lazyfleet_say "  setup  " "nothing (no setup= configured)"
    _lazyfleet_say_ignored setup
    _lazyfleet_ensure $p
  fi
}

# lazyfleet new <branch> | --pr <n> | --issue <n> [-r repo] [-b base] [--no-open] [-q (summary only in the session)]
_lazyfleet_new() {
  local -a o_r o_b o_n o_q o_pr o_is
  zparseopts -D -E -F r:=o_r b:=o_b -no-open=o_n q=o_q -pr:=o_pr -issue:=o_is || return 1
  local _lazyfleet_quiet=${o_q:+1}
  local br=$1 repo p src=
  # zparseopts leaves the = of --pr=7 on the value
  (( $#o_pr )) && o_pr[2]=${o_pr[2]#=}
  (( $#o_is )) && o_is[2]=${o_is[2]#=}
  local usage='usage: lazyfleet new <branch> | --pr <number> | --issue <number>  [-r repo] [-b base] [--no-open]'
  (( $#o_pr + $#o_is > 2 )) && { _lazyfleet_err "give --pr or --issue, not both"; return 1 }
  if (( $#o_pr + $#o_is )); then
    [[ -z $br ]] || { _lazyfleet_err "give a branch, or --pr / --issue, not both"; return 1 }
  elif [[ -z $br ]]; then
    _lazyfleet_err $usage; return 1
  fi
  if (( $#o_r )); then
    _lazyfleet_find_repo $o_r[2] || _lazyfleet_toplevel $o_r[2] || { _lazyfleet_err "unknown repo: $o_r[2]"; return 1 }
  else
    _lazyfleet_toplevel || { _lazyfleet_err 'not in a repo; pass -r <repo>'; return 1 }
  fi
  repo=$REPLY
  if (( $#o_pr )); then
    _lazyfleet_new_from_pr $repo $o_pr[2] || return 1
    br=$REPLY src="pull request #$o_pr[2]"
  elif (( $#o_is )); then
    _lazyfleet_new_from_issue $repo $o_is[2] || return 1
    br=$REPLY src="issue #$o_is[2]"
  fi
  # unregistered (e.g. a name clash) means no worktree: it'd share that name's
  # sessions and dir, and be missing from the lists
  _lazyfleet_add $repo >/dev/null || return 1
  _lazyfleet_setting worktrees LAZYFLEET_WORKTREES ~/.lazyfleet/worktrees
  p=${~REPLY}/${repo:t}/${br//\//-}
  [[ -e $p ]] && { _lazyfleet_err "already exists: $p"; return 1 }
  # what we did goes to stderr (stdout is the path, for scripts and the TUI)
  _lazyfleet_new_checkout $repo $br $p "${o_b[2]}" $src || return 1
  _lazyfleet_new_copy $repo $p || return 1
  _lazyfleet_new_setup $repo $p || return 1
  print -r -- $p
  (( $#o_n )) || _lazyfleet_open_path $p
}

# lazyfleet open [worktree] — no match falls back to the TUI with a query
_lazyfleet_open() {
  if [[ -z $1 ]]; then
    local top
    top=$(git rev-parse --show-toplevel 2>/dev/null) && { _lazyfleet_open_path $top; return }
    _lazyfleet_ui
  elif _lazyfleet_resolve $1; then
    _lazyfleet_open_path $REPLY
  else
    _lazyfleet_ui $1
  fi
}

# REPLY="locked by <owner>" / "locked (<reason>)" if worktree $1 is locked
# (e.g. by Supacode, which writes JSON with an owner); fails if it isn't
_lazyfleet_locked() {
  local gd why
  gd=$(git -C $1 rev-parse --absolute-git-dir 2>/dev/null) && [[ -e $gd/locked ]] || return 1
  why=$(<$gd/locked)
  if [[ $why == *'"owner":"'* ]]; then
    REPLY="locked by ${${why#*\"owner\":\"}%%\"*}"
  else
    REPLY="locked${why:+ ($why)}"
  fi
}

# lazyfleet rm [worktree] [-f] [-D] — -f also overrides a lock
# reply=("kind<TAB>window<TAB>state" ...): the agents running in tmux session
# $1 (the state is empty when it is not known)
_lazyfleet_session_agents() {
  emulate -L zsh
  local line
  local -a f found
  _lazyfleet_agents -d
  for line in $reply; do
    f=("${(@ps:\t:)line}")
    [[ $f[1] == $1 ]] && found+=("$f[3]"$'\t'"$f[2]"$'\t'"$f[4]")
  done
  reply=($found)
}

# Tell (on stdout) which agents $@ ("kind<TAB>window<TAB>state" entries) would
# be ended by closing session $s
_lazyfleet_agents_warning() {
  emulate -L zsh
  local s=$1 e kind win state
  shift
  print -r -- $'\e[33mWarning:\e[0m '"$# agent(s) running in this worktree's tmux session ($s):"
  for e in "$@"; do
    kind=${e%%$'\t'*}; e=${e#*$'\t'}; win=${e%%$'\t'*}; state=${e#*$'\t'}
    print -r -- "   $kind (window $win${state:+, $state})"
  done
}

_lazyfleet_rm() {
  local -a o_f o_D rmf
  zparseopts -D -E -F f=o_f D=o_D || return 1
  local p repo br s rc=0
  _lazyfleet_worktree_arg $1 'usage: lazyfleet rm <worktree>' || return 1
  p=$REPLY
  _lazyfleet_toplevel $p || { _lazyfleet_err "not a git worktree: $p"; return 1 }
  repo=$REPLY
  [[ ${p:A} == ${repo:A} ]] && { _lazyfleet_err "refusing to remove the main worktree: $p"; return 1 }
  _lazyfleet_rm_confirm $p $repo ${o_f:+-f} || return 1
  rmf=(${=REPLY})
  _lazyfleet_branch_of $p; br=$REPLY
  _lazyfleet_session $repo $p 0; s=$REPLY
  _lazyfleet_step "Removing ${p/#$HOME/~} (this can take a while with node_modules)"
  git -C $repo worktree remove $rmf $p
  _lazyfleet_done || return 1
  if (( $#o_D )) && [[ -n $br ]]; then
    _lazyfleet_step "Deleting local branch $br"
    git -C $repo branch -q -D $br
    _lazyfleet_done || rc=1
  fi
  if _lazyfleet_tmux has-session -t "=$s" 2>/dev/null; then
    # last: this may kill the shell we are running in
    _lazyfleet_step "Closing tmux session $s"
    print -u2
    _lazyfleet_tmux kill-session -t "=$s"
  fi
  return rc
}

# Ask before removing worktree $1 of repo $2 when it is locked, has changes,
# or has agents running in its session; -f as $3 skips the questions that
# only -f may skip (all but the lock's, which -f answers). REPLY=the flags
# git worktree remove then needs: --force once, or twice for a lock.
# Fails when the answer is no, or when it would ask off a terminal.
_lazyfleet_rm_confirm() {
  local p=$1 repo=$2 explicit= force= locked= s
  local -a busy
  [[ $3 == -f ]] && explicit=1 force=1
  if _lazyfleet_locked $p; then
    locked=1
    if [[ -z $force ]]; then
      _lazyfleet_confirm "${p/#$HOME/~} is $REPLY. Remove anyway?" "$p is $REPLY (use -f)" || return 1
      force=1
    fi
  fi
  # only an explicit -f skips this: accepting the lock prompt above doesn't
  if [[ -z $explicit && -n $(git -C $p status --porcelain 2>/dev/null) ]]; then
    _lazyfleet_confirm "${p/#$HOME/~} has uncommitted changes. Remove anyway?" "$p has changes (use -f)" || return 1
    force=1
  fi
  # removing the worktree closes its session, and with it the agents in there;
  # like the changes above, only an explicit -f skips the question
  if [[ -z $explicit ]]; then
    _lazyfleet_session $repo $p 0; s=$REPLY
    _lazyfleet_session_agents $s
    if (( $#reply )); then
      busy=("${reply[@]}")
      [[ -t 0 ]] || { _lazyfleet_err "$p has $#busy agent(s) running in session $s (use -f)"; return 1 }
      _lazyfleet_agents_warning $s "${busy[@]}"
      _lazyfleet_ask "Removing the worktree ends them. Remove anyway?" || return 1
    fi
  fi
  # git wants --force twice for a locked worktree
  REPLY=
  [[ -n $force ]] && REPLY="--force${locked:+ --force}"
  return 0
}

# lazyfleet pull [worktree] — fast-forward it to its upstream (never merges)
_lazyfleet_pull() {
  local p br out
  _lazyfleet_worktree_arg $1 'usage: lazyfleet pull <worktree>' || return 1
  p=$REPLY
  _lazyfleet_need_branch $p || return 1
  br=$REPLY
  _lazyfleet_step "Pulling $br in ${p/#$HOME/~}"
  # git's own output only when it fails: it would land after the "… "
  out=$(git -C $p pull -q --ff-only 2>&1)
  _lazyfleet_done || { print -ru2 -- $out; return 1 }
}

# REPLY=dir of the TUI's background pulls: a file per worktree being pulled
# (its path with / as %), and <that>.err with the output of a failed one
_lazyfleet_pulldir() {
  _lazyfleet_tmpdir 2>/dev/null || return 1
  REPLY+=/pull
  [[ -d $REPLY ]] || mkdir -m 700 $REPLY 2>/dev/null
}

# Send fzf action $1 to the TUI's fzf, through its --listen socket ($FZF_SOCK)
_lazyfleet_fzfpost() {
  setopt local_options no_multibyte  # Content-Length counts bytes
  local fd r
  [[ -S $FZF_SOCK ]] || return 1
  zmodload zsh/net/socket || return 1
  zsocket $FZF_SOCK 2>/dev/null || return 1
  fd=$REPLY
  print -rn -- "POST / HTTP/1.1"$'\r\n'"Host: lazyfleet"$'\r\n'"Content-Length: $#1"$'\r\n\r\n'"$1" >&$fd
  read -r -t 5 r <&$fd
  exec {fd}>&-
  [[ $r == 'HTTP/1.1 200'* ]]
}

# Progress for slow steps, on stderr: "msg… " now, then "done"/"failed" by the
# status of the command run in between
_lazyfleet_step() { print -nu2 -- "$1… " }
_lazyfleet_done() {
  local rc=$?
  (( rc )) && print -u2 failed || print -u2 done
  return rc
}

# lazyfleet config [repo] — edit the global settings, or a repo's own config
# file, in $VISUAL/$EDITOR; a missing file starts as a commented example
_lazyfleet_config() {
  local f repo
  if [[ -n $1 ]]; then
    _lazyfleet_find_repo $1 || _lazyfleet_toplevel $1 || { _lazyfleet_err "unknown repo: $1"; return 1 }
    repo=$REPLY
    _lazyfleet_projconf $repo; f=$REPLY
  else
    _lazyfleet_regfile; f=${REPLY:h}/config
  fi
  if [[ ! -e $f ]]; then
    mkdir -p ${f:h}
    if [[ -n $repo ]]; then
      {
        print -r -- "# lazyfleet config for ${repo:t} (${repo/#$HOME/~}). Lines starting with # are ignored."
        print -r -- "# Used for new worktrees; wins over the repo's .lazyfleet. Indent lines to continue a value."
        print -r -- "# copy=.env .env.local"
        print -r -- "# setup="
        print -r -- "#   npm ci"
        if [[ -r $repo/.lazyfleet ]]; then
          print -r -- "#"
          print -r -- "# The repo's .lazyfleet currently has:"
          print -rl -- "#   "${^${(f)"$(<$repo/.lazyfleet)"}}
        fi
      } >$f
    else
      cat >$f <<'EOF'
# lazyfleet settings. Lines starting with # are ignored.
# Env vars LAZYFLEET_SEARCH, LAZYFLEET_SEARCH_DEPTH, LAZYFLEET_WORKTREES and
# LAZYFLEET_STATUS_BRANCH win over these. Per-project copy=/setup= go in
# projects/<name>.conf (press c on a project in lazyfleet).
# search=~/Projects ~/work
# search_depth=4
# worktrees=~/.lazyfleet/worktrees
# status_branch=off   (no branch in the tmux status bar of new sessions)
# update_check=off     (don't look for a newer release once a day; LAZYFLEET_UPDATE_CHECK)
# agent_icons=off      (no ✻ Claude Code / ✦ Copilot CLI / π omp marks on worktrees and windows; LAZYFLEET_AGENT_ICONS)
# pr_status=off        (no pull request / CI marks on worktrees; LAZYFLEET_PR_STATUS)
# trust_branch_config=on  (run setup=/copy= from a branch's own .lazyfleet even when it differs from the main worktree's; LAZYFLEET_TRUST_BRANCH_CONFIG)
EOF
    fi
  fi
  ${=${VISUAL:-${EDITOR:-vi}}} $f
}
