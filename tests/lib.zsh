# Shared by the test suites: `source ${0:A:h}/lib.zsh` once ROOT is set.
#
# A suite is a script that runs checks and ends with `finish`. It exits 0 when
# every check passed, 1 when one failed and 2 when this machine cannot run it
# (see need_tools): tests/all.zsh tells those apart.

typeset -gi fails=0

ok()   { print -P "%F{green}ok%f   $1" }
fail() { print -P "%F{red}FAIL%f $1"; (( fails++ )) }
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

# Poll instead of sleeping: up to 6 seconds, so a loaded machine only makes a
# suite slower, not wrong.
# retry <command string>
retry() { local i; for i in {1..60}; do eval "$1" && return 0; sleep 0.1; done; return 1 }
# waitfor <path>: until it exists
waitfor() { local i; for i in {1..60}; do [[ -e $1 ]] && return 0; sleep 0.1; done; return 1 }
# waitfor_gone <path>: until it no longer exists
waitfor_gone() { local i; for i in {1..60}; do [[ -e $1 ]] || return 0; sleep 0.1; done; return 1 }
# waitpane <session> <text>: until the session's pane shows the text (a fixed
# string, not a pattern). Needs lazyfleet.zsh sourced, for _lazyfleet_tmux.
waitpane() {
  local i
  for i in {1..60}; do
    _lazyfleet_tmux capture-pane -p -t "=$1:" 2>/dev/null | grep -qF -- "$2" && return 0
    sleep 0.1
  done
  return 1
}

# End of a suite: the verdict and the exit status
finish() {
  if (( fails )); then print -P "\n%F{red}$fails failed%f"; exit 1; fi
  print -P "\n%F{green}all passed%f"
}

# need_tools <tool>...: exit 2 with a clear message when a tool the suite runs
# is missing, or when fzf is older than lazyfleet's minimum. (A distro's old
# fzf used to fail the TUI checks one by one, with no hint why.)
need_tools() {
  local t v min=0.58   # the first fzf with --style, as in lazyfleet doctor
  autoload -Uz is-at-least
  for t in "$@"; do
    (( $+commands[$t] )) || { print -u2 -- "tests: $t is not installed; this suite needs it"; exit 2 }
    if [[ $t == fzf ]]; then
      v=${${(z)$(fzf --version 2>/dev/null)}[1]}
      is-at-least $min $v || { print -u2 -- "tests: fzf $v is too old; this suite needs $min or newer"; exit 2 }
    fi
  done
}
