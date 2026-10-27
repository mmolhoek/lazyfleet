#!/usr/bin/env -S zsh -f
# Tests for `lazyfleet doctor`. The tools it looks for are stubs in a directory
# that is the whole PATH, so "not installed" is real and no network is touched.

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools git
SANDBOX=${$(mktemp -d):A}
trap 'rm -rf $SANDBOX' EXIT
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg TMPDIR=$SANDBOX/tmp
mkdir -p $HOME $TMPDIR $SANDBOX/bin $SANDBOX/inst/bin
print '#!/bin/sh' >$SANDBOX/inst/bin/lazyfleet-hook; chmod +x $SANDBOX/inst/bin/lazyfleet-hook
unset LAZYFLEET_PR_STATUS LAZYFLEET_TMUX CLAUDE_CONFIG_DIR TMUX
source $ROOT/lazyfleet.zsh
LAZYFLEET_DIR=$SANDBOX/inst
realpath=$PATH
BIN=$SANDBOX/bin

has() { [[ $out == *${~${(b)1}}* ]] }       # does the last output contain $1?
hasnot() { [[ $out != *${~${(b)1}}* ]] }

# a stub tool that prints $2 when run as `name args`; $3 is its exit status
stub() {
  printf '#!/bin/sh\nprintf "%%s\\n" %s\nexit %s\n' "${(qq)2}" "${3:-0}" >$BIN/$1
  chmod +x $BIN/$1
}
# a good set of tools; each test then breaks what it wants to
tools() {
  rm -f $BIN/*(N)
  stub git 'git version 2.43.0'
  stub tmux 'tmux 3.4'
  stub fzf '0.74 (devel)'
  stub curl ''
  stub gh 'gh version 2.40.1'
}
reset() {
  tools
  rm -rf $XDG_CONFIG_HOME $HOME/.claude
  rm -f $LAZYFLEET_DIR/VERSION
  unset LAZYFLEET_PR_STATUS CLAUDE_CONFIG_DIR
  LAZYFLEET_TMUX=
  unset LAZYFLEET_TMUX
}
# run doctor with only the stubs on PATH; sets $out and $rc
run() {
  local PATH=$BIN
  out=$(_lazyfleet_doctor 2>&1); rc=$?
}
reg() { mkdir -p $XDG_CONFIG_HOME/lazyfleet; print -rl -- "$@" >$XDG_CONFIG_HOME/lazyfleet/repos }

# --- judging a version
judge() { out=$(_lazyfleet_doctor_judge "$@" 2>&1) }
judge tool 'tool 1.2.3' 1.2.3 fail hint;   check 'the minimum itself is fine'        has '  ok    tool 1.2.3'
judge tool 'tool 2.0.0' 1.2.3 fail hint;   check 'a newer version is fine'           has '  ok    tool 2.0.0'
judge tool '3.10' 3.9 fail hint;           check 'versions compare numerically'      has '  ok    tool 3.10'
judge tool 'tool 1.2.2' 1.2.3 fail hint;   check 'an older one is reported at the given level' has 'FAIL  tool 1.2.2 is too old: lazyfleet needs 1.2.3 or newer'
judge tool 'tool 1.2.2' 1.2.3 warn hint;   check 'an older one can only warn'        has 'warn  tool 1.2.2 is too old'
judge tool 'tool 1.2.2' 1.2.3 fail 'do this'; check 'a too old tool says how to fix it' has 'try: do this'
judge tmux 'tmux 3.3a' 3.0 fail h;         check 'a letter after the version is ignored' has '  ok    tmux 3.3'
judge tmux 'tmux next-3.5' 3.0 fail h;     check 'a next-version prefix is ignored'  has '  ok    tmux 3.5'
judge fzf '0.74 (devel)' 0.58 fail h;      check 'text after the version is ignored' has '  ok    fzf 0.74'
judge git 'git version 2.39.3 (Apple Git-145)' 2.17 fail h; check 'Apple git is read' has '  ok    git 2.39.3'
judge fzf '0.100' 0.58 fail h;             check '0.100 is newer than 0.58'          has '  ok    fzf 0.100'
judge fzf '0.9' 0.58 fail h;               check '0.9 is older than 0.58 (dotted, not decimal)' has 'FAIL  fzf 0.9 is too old'
judge tool 'no digits here' 1.0 fail h;    check 'no version number is a warning, not a failure' has 'warn  tool: cannot tell the version'
judge tool '' 1.0 fail h;                  check 'no output at all is a warning'     has 'warn  tool: cannot tell the version'
judge tool $'1.0\e[31mred' 5.0 fail h;     check 'control characters are removed'    hasnot $'\e'

# --- counting
_lazyfleet_doctor_fails=0 _lazyfleet_doctor_warns=0
_lazyfleet_doctor_report ok a >/dev/null; _lazyfleet_doctor_report warn b >/dev/null; _lazyfleet_doctor_report warn c >/dev/null; _lazyfleet_doctor_report fail d >/dev/null
check 'warnings are counted' test $_lazyfleet_doctor_warns = 2
check 'failures are counted' test $_lazyfleet_doctor_fails = 1
check 'ok is not counted' test $(( _lazyfleet_doctor_warns + _lazyfleet_doctor_fails )) = 3
out=$(_lazyfleet_doctor_report ok text)
check 'no colour when the output is not a terminal' hasnot $'\e'
out=$(_lazyfleet_doctor_report warn 'a'$'\e[2Jb' fix$'\e[2J')
check 'control characters in a finding are removed' hasnot $'\e'

# --- the whole thing
reset; run
check 'a complete setup passes'            test $rc = 0
check 'it names itself'                    has 'lazyfleet doctor'
check 'it reports git'                     has '  ok    git 2.43.0'
check 'it reports tmux'                    has '  ok    tmux 3.4'
check 'it reports fzf'                     has '  ok    fzf 0.74'
check 'it reports zsh'                     has "  ok    zsh $ZSH_VERSION"
check 'it reports curl'                    has '  ok    curl'
check 'it reports gh logged in'            has 'gh is logged in'
check 'no repositories is not a problem'   has 'no repositories registered yet'
check 'with nothing wrong it says so'      has 'All good.'

reset; rm $BIN/git; run
check 'a missing git fails'                test $rc = 1
check 'a missing git is named'             has 'FAIL  git is not installed'
check 'it says how to install it'          has 'try: macOS: brew install git'
check 'the summary counts the problem'     has '1 problem(s)'
reset; rm $BIN/tmux; run
check 'a missing tmux fails'               has 'FAIL  tmux is not installed'
reset; rm $BIN/fzf; run
check 'a missing fzf fails'                has 'FAIL  fzf is not installed'
reset; stub fzf '0.57.2'; run
check 'fzf 0.57 is too old'                has 'FAIL  fzf 0.57.2 is too old: lazyfleet needs 0.58 or newer'
check 'an old fzf makes doctor fail'       test $rc = 1
reset; stub fzf '0.58.0'; run
check 'fzf 0.58 is enough'                 test $rc = 0
reset; stub tmux 'tmux 2.9'; run
check 'an old tmux only warns'             has 'warn  tmux 2.9 is too old'
check 'an old tmux does not fail doctor'   test $rc = 0
check 'warnings are summed up'             has 'No problems, 1 warning(s).'
reset; stub git 'git version 2.10.0'; run
check 'an old git only warns'              has 'warn  git 2.10.0 is too old'
reset; stub fzf 'broken' 1; run
check 'a tool that prints no version warns' has 'warn  fzf: cannot tell the version'
reset; rm $BIN/git $BIN/tmux $BIN/fzf; run
check 'every problem is listed'            has '3 problem(s)'
check 'all of them are listed'             eval '[[ $out == *git\ is\ not* && $out == *tmux\ is\ not* && $out == *fzf\ is\ not* ]]'
reset; stub git $'git version 2.43.0\nsecond line 1.0.0'; run
check 'only the first line of output is read' has '  ok    git 2.43.0'
reset; stub git $'warning: no version here\nsecond line 9.9.9'; run
check 'a number on a later line is not taken for the version' has 'warn  git: cannot tell the version'

# the tmux in use is the one lazyfleet is configured with
reset; stub other 'tmux 3.5'; LAZYFLEET_TMUX="$BIN/other -L x"; run
check 'LAZYFLEET_TMUX picks the tmux that is checked' has '  ok    tmux 3.5'
unset LAZYFLEET_TMUX

reset; stub other 'tmux 3.5'; LAZYFLEET_TMUX="$BIN/nothere -L x"; run
check 'a tmux path that is not there fails' has 'FAIL  tmux is not installed'
unset LAZYFLEET_TMUX

# --- optional tools
reset; rm $BIN/curl; run
check 'no curl is a warning'               has 'warn  curl is not installed'
check 'no curl does not fail doctor'       test $rc = 0
reset; rm $BIN/gh; run
check 'no gh is a warning'                 has 'warn  gh is not installed: no pull request marks'
check 'no gh says where to get it'         has 'try: https://cli.github.com'
reset; stub gh '' 1; run
check 'a gh without login is a warning'    has 'warn  gh has no login'
check 'it says how to log in'              has 'try: gh auth login'
reset; rm $BIN/gh; LAZYFLEET_PR_STATUS=off run
check 'pr_status=off needs no gh'          has 'pull request marks are off'
check 'pr_status=off does not warn'        hasnot 'gh'
reset; rm $BIN/gh; mkdir -p $XDG_CONFIG_HOME/lazyfleet; print 'pr_status=off' >$XDG_CONFIG_HOME/lazyfleet/config; run
check 'the config file turns the check off too' has 'pull request marks are off'

# --- Claude Code hooks (only when Claude Code is there)
reset; run
check 'without claude, hooks are not mentioned' hasnot 'hooks'
reset; stub claude 'claude 1'; run
check 'claude without jq warns about jq'   has 'warn  jq is not installed'
if (( $+commands[jq] )); then
  ln -sf $commands[jq] $BIN/jq
  reset; stub claude 'claude 1'; ln -sf $commands[jq] $BIN/jq; run
  check 'claude without hooks warns'       has 'warn  Claude Code hooks are not installed'
  check 'it says how to install them'      has 'try: lazyfleet hooks install'
  PATH=$BIN:$realpath _lazyfleet_hooks install >/dev/null 2>&1
  run
  check 'with hooks installed it is happy' has '  ok    Claude Code hooks are installed'
else
  skip 'hooks installed / not installed' 'jq is not installed'
fi

# --- the registry
reset; mkdir -p $SANDBOX/r1 $SANDBOX/r2; reg $SANDBOX/r1; run
check 'one repository is counted'          has '1 repository registered'
reg $SANDBOX/r1 $SANDBOX/r2; run
check 'repositories are counted'           has '2 repositories registered'
reg $SANDBOX/r1 $SANDBOX/gone; run
check 'a repository that is gone is a warning' has "warn  $SANDBOX/gone no longer exists"
check 'it suggests forgetting it'          has 'try: lazyfleet forget gone'
check 'a gone repository does not fail doctor' test $rc = 0
reg $SANDBOX/r1; for i in {1..8}; do print -r -- $SANDBOX/gone$i >>$XDG_CONFIG_HOME/lazyfleet/repos; done; run
check 'only the first five missing ones are listed' eval '[[ $out == *gone5\ no* && $out != *gone6\ no* ]]'
check 'the rest are counted'               has 'and 3 more missing'
reg $SANDBOX/r1 "$SANDBOX/ev"$'\e[2J'"il"; run
check 'control characters in a path are removed' hasnot $'\e'

# --- this installation
reset; print -r -- 0.3.1 >$LAZYFLEET_DIR/VERSION; run
check 'a release install shows its version' has "lazyfleet v0.3.1 in $LAZYFLEET_DIR"
reset; print -r -- feat/x >$LAZYFLEET_DIR/VERSION; run
check 'a branch install says so'            has 'lazyfleet feat/x (branch)'
reset; run
check 'a checkout says so'                  has 'from a checkout'

# --- wiring
reset
out=$(PATH=$BIN _lazyfleet_main doctor 2>&1); rc=$?
check 'the doctor command runs'            has 'lazyfleet doctor'
check 'the doctor command passes the exit status on' test $rc = 0
rm $BIN/fzf; out=$(PATH=$BIN _lazyfleet_main doctor 2>&1); rc=$?
check 'the doctor command fails when something is missing' test $rc = 1
out=$(_lazyfleet_help 2>&1)
check 'help lists doctor'                  has 'lazyfleet doctor'
check 'completion lists doctor'            grep -q "'doctor:" $ROOT/_lazyfleet
fzf_installer=$(sed -n 's/^MIN_FZF=\([0-9.]*\).*/\1/p' $ROOT/install.sh)
check 'the installer and doctor agree on the fzf minimum' test "$fzf_installer" = "$_LAZYFLEET_MIN_FZF"

finish
