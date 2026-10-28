# Shared by the test suites: `source ${0:A:h}/lib.zsh` once ROOT is set.
#
# A suite is a script that runs checks and ends with `finish`. It exits 0 when
# every check passed, 1 when one failed and 2 when this machine cannot run it
# (see need_tools): tests/all.zsh tells those apart.

# Failures are counted in a file, not a variable: a check inside a ( )
# subshell must still fail the suite
typeset -g _test_failfile=$(mktemp "${TMPDIR:-/tmp}/lf-fails.XXXXXX")
fails() { REPLY=$(wc -l <$_test_failfile 2>/dev/null | tr -d ' '); REPLY=${REPLY:-0} }

ok()   { print -P "%F{green}ok%f   $1" }
fail() { print -P "%F{red}FAIL%f $1"; print x >>$_test_failfile }
skip() { print -P "%F{yellow}skip%f $1 ($2)" }

# check <description> <command...>: ok when the command succeeds
check() { local d=$1; shift; if "$@"; then ok $d; else fail $d; fi }
# check, unless the reason in $1 (when not empty) rules it out here
check_unless() { local why=$1; shift; if [[ -n $why ]]; then skip "$1" "$why"; else check "$@"; fi }

# A failed assertion shows what it got, not only its description
# assert_eq <description> <expected> <actual>
assert_eq() {
  if [[ $3 == "$2" ]]; then ok $1; else
    fail $1
    print -r -- "       expected: ${(q+)2}"
    print -r -- "       actual:   ${(q+)3}"
  fi
}
# assert_contains <description> <needle> <haystack>
assert_contains() {
  if [[ $3 == *"$2"* ]]; then ok $1; else
    fail $1
    print -r -- "       expected to contain: ${(q+)2}"
    print -r -- "       actual:              ${(q+)3}"
  fi
}

# like grep, but quiet and reading all of its input: with pipe_fail, an early
# exit would fail the producer with SIGPIPE
gq() { grep "$@" >/dev/null 2>&1 }
not() { ! "$@" }

# Poll instead of sleeping: up to 15 seconds, so a loaded machine only makes a
# suite slower, not wrong. (6 s was not always enough on a busy runner.)
# retry <command string>
retry() { local i; for i in {1..150}; do eval "$1" && return 0; sleep 0.1; done; return 1 }
# waitfor <path>: until it exists
waitfor() { local i; for i in {1..150}; do [[ -e $1 ]] && return 0; sleep 0.1; done; return 1 }
# waitfor_gone <path>: until it no longer exists
waitfor_gone() { local i; for i in {1..150}; do [[ -e $1 ]] || return 0; sleep 0.1; done; return 1 }
# waitpane <session> <text>: until the session's pane shows the text (a fixed
# string, not a pattern). Needs lazyfleet.zsh sourced, for _lazyfleet_tmux.
waitpane() {
  local i
  for i in {1..150}; do
    _lazyfleet_tmux capture-pane -p -t "=$1:" 2>/dev/null | grep -qF -- "$2" && return 0
    sleep 0.1
  done
  return 1
}

# use_tmux <name>: give the suite a tmux server of its own, lf-<name>-<pid>,
# with its socket in the sandbox ($SANDBOX must be set), so it goes away with
# it. A unix socket path holds 103 bytes on macOS, whose temp dirs are already
# about 70 long: when $TMUX_TMPDIR/tmux-UID/NAME would not fit, the socket
# goes to a short dir in /tmp instead. tmux_cleanup removes both.
typeset -g _test_tmux= _test_tmux_dir=
use_tmux() {
  local dir=${SANDBOX:?use_tmux needs SANDBOX}
  _test_tmux=lf-$1-$$
  if (( $#dir + ${#:-/tmux-$UID/} + $#_test_tmux > 100 )); then
    dir=$(mktemp -d /tmp/lf.XXXXXX) || cannot_run "cannot make a short dir for the tmux socket"
    _test_tmux_dir=$dir
  fi
  unset TMUX TMUX_PANE
  export TMUX_TMPDIR=$dir LAZYFLEET_TMUX="tmux -L $_test_tmux"
}
# tmux_cleanup: stop the suite's tmux server and remove a short socket dir
tmux_cleanup() {
  [[ -n $_test_tmux ]] && command tmux -L $_test_tmux kill-server 2>/dev/null
  [[ -n $_test_tmux_dir ]] && rm -rf $_test_tmux_dir
  return 0
}

# waitcmd <session> <command>: until the session's pane runs that command
# (e.g. the `sleep` a test pane ends with: what ran before it has returned).
# Needs lazyfleet.zsh sourced, for _lazyfleet_tmux.
waitcmd() {
  local i
  for i in {1..150}; do
    [[ $(_lazyfleet_tmux display-message -p -t "=$1:" '#{pane_current_command}' 2>/dev/null) == $2 ]] && return 0
    sleep 0.1
  done
  return 1
}

# End of a suite: the verdict and the exit status
finish() {
  fails; local n=$REPLY
  rm -f $_test_failfile
  if (( n )); then print -P "\n%F{red}$n failed%f"; exit 1; fi
  print -P "\n%F{green}all passed%f"
}

# cannot_run <why>: this machine cannot run the suite: say why, exit 2
cannot_run() { print -u2 -- "tests: $1"; rm -f $_test_failfile; exit 2 }

# need_tools <tool>...: exit 2 with a clear message when a tool the suite runs
# is missing, or when fzf is older than lazyfleet's minimum. (A distro's old
# fzf used to fail the TUI checks one by one, with no hint why.)
need_tools() {
  local t v min=0.58   # the first fzf with --style, as in lazyfleet doctor
  autoload -Uz is-at-least
  for t in "$@"; do
    (( $+commands[$t] )) || cannot_run "$t is not installed; this suite needs it"
    if [[ $t == fzf ]]; then
      v=${${(z)$(fzf --version 2>/dev/null)}[1]}
      is-at-least $min $v || cannot_run "fzf $v is too old; this suite needs $min or newer"
    fi
  done
}
