#!/usr/bin/env -S zsh -f
# Run the test suites, each in its own process, and summarise.
#
#   zsh tests/all.zsh                 every suite in tests/
#   zsh tests/all.zsh prune doctor    just these (a name, or a path to a suite)
#   zsh tests/all.zsh -v              show each suite's whole output
#
# Exit status: 0 when every suite passed, 1 otherwise. A suite that cannot run
# here (a missing tool, an fzf that is too old: it exits 2) counts as a failure,
# so a CI machine that lacks something does not look green.

zmodload zsh/datetime
dir=${0:A:h}
verbose=
[[ $1 == -v ]] && { verbose=1; shift }

typeset -a suites
if (( $# )); then
  for a in "$@"; do
    if [[ -f $a ]]; then suites+=(${a:A})
    elif [[ ${a%.zsh} != (lib|all) && -f $dir/${a%.zsh}.zsh ]]; then suites+=($dir/${a%.zsh}.zsh)
    else print -u2 -- "tests: no suite called $a"; exit 1
    fi
  done
else
  suites=($dir/*.zsh(N))
  suites=(${suites:#$dir/(lib|all).zsh})
fi
(( $#suites )) || { print -u2 -- "tests: no suites found"; exit 1 }

strip() { sed $'s/\x1b\\[[0-9;]*m//g' }
log=$(mktemp -d)/out
trap 'rm -rf ${log:h}' EXIT

typeset -i failed=0 oks=0 fails=0 skips=0
typeset -a problems
printf '%-24s %-10s %4s %5s %5s  %s\n' suite result ok FAIL skip time
for s in $suites; do
  start=$EPOCHREALTIME
  zsh -f $s >$log 2>&1
  rc=$?
  secs=$(( EPOCHREALTIME - start ))
  plain=$(strip <$log)
  o=${#${(M)${(f)plain}:#ok *}} f=${#${(M)${(f)plain}:#FAIL *}} k=${#${(M)${(f)plain}:#skip *}}
  # a FAIL line fails the suite, whatever its exit status says
  (( rc == 0 && f )) && rc=1
  case $rc in
    (0) res=pass ;;
    (2) res=cannot-run ;;
    (*) res=FAIL ;;
  esac
  printf '%-24s %-10s %4d %5d %5d  %5.1fs\n' ${s:t:r} $res $o $f $k $secs
  oks+=o fails+=f skips+=k
  if [[ -n $verbose ]]; then
    print -r -- $plain
  elif (( rc )); then
    problems+=("${s:t:r}:"${(f)"$(grep -E '^(FAIL|tests:|       )' <<<$plain | head -20)"})
  fi
  # on GitHub Actions, also as an annotation: it shows on the pull request,
  # and through the API, where the log itself may not be reachable
  if (( rc )) && [[ -n $GITHUB_ACTIONS ]]; then
    msg=$(grep -E '^(FAIL|tests:|       )' <<<$plain | head -20)
    [[ -n $msg ]] || msg=$(tail -n 15 <<<$plain)
    msg=${msg//'%'/%25}; msg=${msg//$'\r'/%0D}; msg=${msg//$'\n'/%0A}
    print -r -- "::error title=test suite ${s:t:r} (exit $rc)::$msg"
  fi
  (( rc )) && failed+=1
done

if (( $#problems )); then print; print -rl -- $problems; fi
print
print -r -- "$#suites suite(s), $oks checks passed, $fails failed, $skips skipped"
if (( failed )); then print -r -- "$failed suite(s) did not pass."; exit 1; fi
print -r -- "All suites passed."
