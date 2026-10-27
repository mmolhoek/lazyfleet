#!/usr/bin/env -S zsh -f
# Tests for tests/all.zsh itself, with made-up suites: its verdict is what a CI
# job goes by, so the exit status and the report have to be right.

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
SANDBOX=${$(mktemp -d):A}
trap 'rm -rf $SANDBOX' EXIT

mk() { print -r -- "$2" >$SANDBOX/$1.zsh }
mk good 'print "ok   one"; print "ok   two"; print "skip three (why)"; exit 0'
mk bad 'print "ok   one"; print "FAIL two"; print "       expected: a"; exit 1'
mk cannot 'print -u2 "tests: fzf 0.1 is too old; this suite needs 0.58 or newer"; exit 2'
run() { zsh -f $ROOT/tests/all.zsh "$@" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g' }

out=$(run $SANDBOX/good.zsh)
zsh -f $ROOT/tests/all.zsh $SANDBOX/good.zsh >/dev/null 2>&1; assert_eq 'a passing suite gives exit 0' 0 $?
assert_contains 'it counts the checks and skips' '1 suite(s), 2 checks passed, 0 failed, 1 skipped' $out
assert_contains 'it says everything passed' 'All suites passed.' $out

out=$(run $SANDBOX/good.zsh $SANDBOX/bad.zsh)
zsh -f $ROOT/tests/all.zsh $SANDBOX/good.zsh $SANDBOX/bad.zsh >/dev/null 2>&1; assert_eq 'one failing suite gives exit 1' 1 $?
assert_contains 'the failing suite is named FAIL in the table' 'bad       ' $out
assert_contains 'the failing check is repeated below the table' 'FAIL two' $out
assert_contains 'with what it expected' 'expected: a' $out
assert_contains 'the verdict names the failure' '1 suite(s) did not pass.' $out
[[ $out != *'All suites passed.'* ]]; assert_eq 'it does not also claim success' 0 $?

out=$(run $SANDBOX/cannot.zsh)
zsh -f $ROOT/tests/all.zsh $SANDBOX/cannot.zsh >/dev/null 2>&1; assert_eq 'a suite that cannot run fails the run' 1 $?
assert_contains 'it is told apart from a failing one' 'cannot-run' $out
assert_contains 'and the reason is shown' 'this suite needs 0.58 or newer' $out

zsh -f $ROOT/tests/all.zsh nosuchsuite >/dev/null 2>&1; assert_eq 'an unknown suite name is an error' 1 $?
out=$(run -v $SANDBOX/good.zsh)
assert_contains '-v shows the suite'"'"'s own output' 'ok   one' $out

# on GitHub Actions a failing suite is also an annotation, with newlines escaped
out=$(GITHUB_ACTIONS=true run $SANDBOX/bad.zsh)
assert_contains 'on GitHub Actions a failure is annotated' '::error title=test suite bad (exit 1)::FAIL two%0A       expected: a' $out
out=$(run $SANDBOX/bad.zsh)
[[ $out != *'::error'* ]]; assert_eq 'elsewhere there are no annotations' 0 $?
mk crash 'print "starting"; print "boom" >&2; exit 7'
out=$(GITHUB_ACTIONS=true run $SANDBOX/crash.zsh)
assert_contains 'a suite that crashed is annotated with its last output' '::error title=test suite crash (exit 7)::starting%0Aboom' $out

# a named suite is found in tests/ without its path or extension
out=$(run lib 2>&1)
assert_contains 'lib is not a suite' 'no suite called lib' "$out"

finish
