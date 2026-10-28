# lazyfleet: Pull request and CI marks (GitHub through gh, cached in the background).
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.

# --- pull requests and CI ---------------------------------------------------
# A worktree whose branch has a GitHub pull request shows it in its row:
# "#12 ✓" (checks pass), "#12 ✗" (a check failed), "#12 …" (checks running),
# "#12" (no checks), "#12 draft", "#12 merged" or "#12 closed". The data comes
# from GitHub's REST API through the gh CLI, is fetched in the background at
# most every _LAZYFLEET_PR_TTL seconds per repo, and cached. Drawing a row only
# ever reads the cache, so the TUI never waits for the network.
# pr_status=off (or LAZYFLEET_PR_STATUS=off) turns it off.

typeset -g _LAZYFLEET_PR_TTL=90

# jq program for a repo's pull requests: one tab-separated line each, with
# branch, number, state, draft, merged, head sha, head repo, url and title.
# Control characters are stripped from the title: it is written by whoever
# opened the pull request and ends up on the terminal.
typeset -g _LAZYFLEET_PR_JQ='.[] | [.head.ref, (.number|tostring), .state, ((.draft // false)|tostring), (if .merged_at then "merged" else "-" end), .head.sha, (.head.repo.full_name // "-"), .html_url, (.title | gsub("[\u0001-\u001f\u007f-\u009f‎‏‪-‮⁦-⁩]"; " "))] | @tsv'
typeset -g _LAZYFLEET_PR_JQ_CHECKS='[.check_runs[] | .status + "/" + (.conclusion // "-")] | join(" ")'
typeset -g _LAZYFLEET_PR_JQ_STATUS='"\(.total_count) \(.state)"'

# REPLY=owner/name of repo $1's GitHub origin; fails for any other host
_lazyfleet_ghslug() {
  emulate -L zsh
  setopt extended_glob
  local u h rest
  u=$(git -C $1 remote get-url origin 2>/dev/null) || return 1
  u=${u%/}; u=${u%.git}
  if [[ $u == *://* ]]; then
    u=${u#*://}                  # scheme://[user[:pass]@]host[:port]/owner/name
    h=${u%%/*}; rest=${u#*/}
    [[ $u == */* ]] || return 1
    h=${h##*@}; h=${h%%:*}
  elif [[ $u == *:* && $u != /* ]]; then
    h=${u%%:*}; rest=${u#*:}     # [user@]host:owner/name
    h=${h##*@}
  else
    return 1
  fi
  [[ ${h:l} == (www.|)github.com ]] || return 1
  [[ $rest == [A-Za-z0-9_.-]##/[A-Za-z0-9_.-]## ]] || return 1
  [[ ${rest%%/*} != (.|..) && ${rest##*/} != (.|..) ]] || return 1
  REPLY=$rest
}

_lazyfleet_pr_enabled() {
  (( $+commands[gh] )) || return 1
  _lazyfleet_flag pr_status LAZYFLEET_PR_STATUS on
}

# REPLY=the cache file of GitHub repo $1 (owner/name); creates the directory
_lazyfleet_pr_cachefile() {
  _lazyfleet_tmpdir 2>/dev/null || return 1
  REPLY+=/pr
  [[ -d $REPLY ]] || mkdir -m 700 $REPLY 2>/dev/null
  REPLY+=/${${1:l}//\//%}
}

# REPLY=pass, fail, pending or none, from $1 (the "status/conclusion" words of
# a commit's check runs) and $2 ("count state" of its combined commit status).
# A commit nothing checks has a combined state of "pending" with a count of 0;
# that is none, not pending.
_lazyfleet_pr_ci() {
  local w fail= pend= pass=
  for w in ${=1}; do
    if [[ ${w%%/*} != completed ]]; then pend=1; continue; fi
    case ${w#*/} in
      (success|neutral|skipped) pass=1 ;;
      (failure|timed_out|cancelled|action_required|startup_failure) fail=1 ;;
      (stale) ;;
      (*) pend=1 ;;
    esac
  done
  if [[ ${2%% *} == <-> ]] && (( ${2%% *} > 0 )); then
    case ${2#* } in
      (failure|error) fail=1 ;;
      (pending) pend=1 ;;
      (success) pass=1 ;;
    esac
  fi
  if [[ -n $fail ]]; then REPLY=fail
  elif [[ -n $pend ]]; then REPLY=pending
  elif [[ -n $pass ]]; then REPLY=pass
  else REPLY=none; fi
}

# _lazyfleet_pr_fetch slug cachefile branch...: ask GitHub about the repo's
# pull requests (and, for open ones on the given branches, their checks) and
# write the cache. If GitHub can not be reached the old rows stay and only the
# time of the attempt moves, so a failure is not retried at once. REPLY=changed
# if the rows differ from before, else same.
_lazyfleet_pr_fetch() {
  local slug=$1 f=$2 out old= new= ok=1
  shift 2
  [[ -r $f ]] && old=$(tail -n +2 $f 2>/dev/null)
  out=$(command gh api "repos/$slug/pulls?state=all&sort=updated&direction=desc&per_page=100" --jq $_LAZYFLEET_PR_JQ 2>/dev/null) || ok=
  if [[ -n $ok ]]; then
    _lazyfleet_pr_best $slug $out
    _lazyfleet_pr_add_checks $slug "$*" $reply
    new=${(F)reply}
  else
    new=$old
  fi
  _lazyfleet_pr_write $f "$ok" $new || return 1
  [[ $new == $old ]] && REPLY=same || REPLY=changed
  [[ -n $ok ]]
}

# reply=(cache lines "branch<TAB>number<TAB>state<TAB>-<TAB>url<TAB>title<TAB>head sha",
# by branch) from $2, GitHub's pull requests of repo $1 as _LAZYFLEET_PR_JQ
# prints them (most recently updated first). Per branch: an open pull request
# beats a merged one beats a closed one; among equals the most recently
# updated (the first) stays. Pull requests from forks are left out. The
# checks (field 4) are filled in by _lazyfleet_pr_add_checks.
_lazyfleet_pr_best() {
  local slug=$1 line st r ref
  local -a fl
  local -A best rank
  for line in ${(f)2}; do
    fl=("${(@ps:\t:)line}")
    (( $#fl >= 8 )) || continue
    [[ ${fl[7]:l} == ${slug:l} ]] || continue          # not from a fork
    if [[ $fl[3] == open ]]; then
      [[ $fl[4] == true ]] && st=draft || st=open; r=4
    elif [[ $fl[5] == merged ]]; then st=merged; r=3
    else st=closed; r=2; fi
    (( r > ${rank[$fl[1]]:-0} )) || continue
    rank[$fl[1]]=$r
    best[$fl[1]]=$fl[2]$'\t'$st$'\t'-$'\t'$fl[8]$'\t'${fl[9]//\\\\/\\}$'\t'$fl[6]
  done
  reply=()
  # (the head commit stays in the cache: prune compares it with a branch)
  for ref in ${(ok)best}; do reply+=($ref$'\t'$best[$ref]); done
}

# reply=the cache lines $3... with the CI state (field 4) of the open pull
# requests whose branch is in $2 (space separated: the branches that have a
# worktree here), at most 25, asked for all at once. $1 is the repo.
_lazyfleet_pr_add_checks() {
  emulate -L zsh
  setopt extended_glob no_monitor no_notify
  local slug=$1 dir row ref st sha i=0 n
  local -a rows=("${(@)argv[3,-1]}") fl
  local -A want at
  for ref in ${=2}; do want[$ref]=1; done
  reply=("${(@)rows}")
  _lazyfleet_tmpdir 2>/dev/null && dir=$REPLY/ci.$$.$RANDOM && mkdir -m 700 $dir 2>/dev/null || return 0
  for (( n = 1; n <= $#rows; n++ )); do
    fl=("${(@ps:\t:)rows[n]}")
    ref=$fl[1] st=$fl[3] sha=$fl[7]
    [[ -n $want[$ref] && $st == (open|draft) && $sha == [0-9a-f](#c7,64) ]] || continue
    (( i >= 25 )) && break
    (( i++ ))
    at[$i]=$n
    {
      command gh api "repos/$slug/commits/$sha/check-runs?per_page=100" --jq $_LAZYFLEET_PR_JQ_CHECKS >$dir/$i.c 2>/dev/null || : >$dir/$i.c
      command gh api "repos/$slug/commits/$sha/status" --jq $_LAZYFLEET_PR_JQ_STATUS >$dir/$i.s 2>/dev/null || : >$dir/$i.s
    } &
  done
  wait
  for i in ${(k)at}; do
    n=$at[$i]
    fl=("${(@ps:\t:)reply[n]}")
    _lazyfleet_pr_ci "$(<$dir/$i.c)" "$(<$dir/$i.s)"
    fl[4]=$REPLY
    reply[n]=${(pj:\t:)fl}
  done
  rm -rf $dir
}

# Write cache file $1: a header (format 1, now, "ok" when $2 is set, else
# "fail"), then the lines $3...; replaced at once, never half written
_lazyfleet_pr_write() {
  local f=$1 st=fail tmp=$1.$$
  [[ -n $2 ]] && st=ok
  shift 2
  {
    print -r -- "#lazyfleet-pr 1 $EPOCHSECONDS $st"
    if (( $# )) && [[ -n $1 ]]; then print -rl -- "$@"; fi
  } >|$tmp && mv -f $tmp $f || { rm -f $tmp; return 1 }
}

# _lazyfleet_pr_read slug: put the cached pull requests of repo $1 into the
# caller's associative array prs, as "slug:branch" ->
# "number<TAB>state<TAB>ci<TAB>url<TAB>title<TAB>head sha". REPLY=seconds since the last
# attempt to refresh the cache (empty: never). Fails without a usable cache.
_lazyfleet_pr_read() {
  local slug=${1:l} f line content stamp
  local -a fl hf lines
  REPLY=
  _lazyfleet_pr_cachefile $slug || return 1; f=$REPLY
  REPLY=
  [[ -r $f ]] || return 1
  content=$(<$f) 2>/dev/null
  lines=("${(@f)content}")
  hf=(${=lines[1]})
  [[ $hf[1] == '#lazyfleet-pr' && $hf[2] == 1 && $hf[3] == <-> ]] || return 1
  stamp=$hf[3]
  for line in ${lines[2,-1]}; do
    fl=("${(@ps:\t:)line}")
    (( $#fl >= 5 )) || continue
    prs[$slug:$fl[1]]=$fl[2]$'\t'$fl[3]$'\t'$fl[4]$'\t'$fl[5]$'\t'${fl[6]//[[:cntrl:]]/ }$'\t'${fl[7]//[^0-9a-f]/}
  done
  REPLY=$(( EPOCHSECONDS - stamp ))
}

# REPLY=the row mark for pull request fields $1 (number) $2 (state) $3 (ci);
# -p as $4 for no colours
_lazyfleet_pr_mark() {
  local n=$1 st=$2 ci=$3 col= sym= end=$'\e[0m'
  case $st in
    (open) case $ci in
             (pass) col=$'\e[32m' sym=' ✓' ;;
             (fail) col=$'\e[31m' sym=' ✗' ;;
             (pending) col=$'\e[33m' sym=' …' ;;
           esac ;;
    (draft) col=$'\e[2m' sym=' draft' ;;
    (merged) col=$'\e[35m' sym=' merged' ;;
    (closed) col=$'\e[2m' sym=' closed' ;;
    (*) REPLY=; return 1 ;;
  esac
  [[ $4 == -p ]] && col=
  [[ -z $col ]] && end=
  REPLY="${col}#${n}${sym}${end}"
}

# Look for pull requests that are out of date, and refresh them in a detached
# job that, once it has found something new, has the TUI's fzf reload. Arguments
# are pairs: a repo's owner/name and its worktrees' branches (space separated).
_lazyfleet_pr_kick() {
  emulate -L zsh
  setopt extended_glob
  local slug f age bin=${(q)LAZYFLEET_DIR}/bin/lazyfleet
  local -a todo dead
  local -A prs
  while (( $# >= 2 )); do
    slug=$1
    _lazyfleet_pr_cachefile $slug || { shift 2; continue }; f=$REPLY
    prs=()
    _lazyfleet_pr_read $slug; age=$REPLY
    if [[ -z $age ]] || (( age >= _LAZYFLEET_PR_TTL )); then
      # one refresh per repo at a time; a lock older than two minutes is dead
      if mkdir $f.lock 2>/dev/null; then
        todo+=($slug $f $2)
      else
        dead=($f.lock(N/mm+2))
        (( $#dead )) && rmdir $f.lock 2>/dev/null
      fi
    fi
    shift 2
  done
  (( $#todo )) || return 0
  {
    local changed= s file brs
    while (( $#todo >= 3 )); do
      s=$todo[1] file=$todo[2] brs=$todo[3]; shift 3 todo
      _lazyfleet_pr_fetch $s $file ${=brs}
      [[ $REPLY == changed ]] && changed=1
      rmdir $file.lock 2>/dev/null
    done
    [[ -n $changed ]] && _lazyfleet_fzfpost "transform($bin _prdone)"
  } </dev/null >/dev/null 2>&1 &!
}

# fzf action once a refresh found something new: reload the worktrees (with
# their git status) unless the list is not on them or is still loading
_lazyfleet_prdone() {
  local bin=${(q)LAZYFLEET_DIR}/bin/lazyfleet lbl=${${FZF_LIST_LABEL# }% }
  case $lbl in
    (Worktrees*' · loading…'|Worktrees*' · checking status…') ;;
    (Worktrees*) print -r -- "reload-sync($bin _rows -s)" ;;
  esac
}
