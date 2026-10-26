#!/usr/bin/env -S zsh -f
# Tests for the update check (no network: curl is a stub).

ROOT=${0:A:h:h}
SANDBOX=${$(mktemp -d):A}
trap 'rm -rf $SANDBOX' EXIT
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg
unset XDG_CACHE_HOME LAZYFLEET_UPDATE_CHECK LAZYFLEET_RELEASES_URL
mkdir -p $HOME $XDG_CONFIG_HOME $SANDBOX/stub $SANDBOX/inst

# curl stub: logs its arguments, fails when STUB_FAIL is set, else answers with
# the url a redirect to the latest release would end at
cat >$SANDBOX/stub/curl <<'STUB'
#!/bin/sh
echo "$*" >>"$STUB_LOG"
[ -n "$STUB_FAIL" ] && exit 22
printf '%s' "$STUB_URL"
STUB
chmod +x $SANDBOX/stub/curl
export STUB_LOG=$SANDBOX/curl.log
path=($SANDBOX/stub $path)

source $ROOT/lazyfleet.zsh
LAZYFLEET_DIR=$SANDBOX/inst
cache=$HOME/.cache/lazyfleet/latest-release
conf=$XDG_CONFIG_HOME/lazyfleet/config

fails=0
ok()   { print -P "%F{green}ok%f   $1" }
fail() { print -P "%F{red}FAIL%f $1"; (( fails++ )) }
check() { local d=$1; shift; if "$@"; then ok $d; else fail $d; fi }
gq() { grep "$@" >/dev/null 2>&1 }
not() { ! "$@" }
retry() { local i; for i in {1..50}; do eval "$1" && return 0; sleep 0.1; done; return 1 }
calls() { [[ -e $STUB_LOG ]] && wc -l <$STUB_LOG | tr -d ' ' || print 0 }
# fresh state: version $1 installed, no cache, no config, no curl calls
reset() {
  rm -rf $HOME/.cache $XDG_CONFIG_HOME/lazyfleet $STUB_LOG $SANDBOX/inst/INSTALLER
  unset STUB_FAIL LAZYFLEET_UPDATE_CHECK
  export STUB_URL=https://github.com/mmolhoek/lazyfleet/releases/tag/v0.2.0
  LAZYFLEET_DIR=$SANDBOX/inst
  [[ -n $1 ]] && print -r -- $1 >$SANDBOX/inst/VERSION || rm -f $SANDBOX/inst/VERSION
}
seed() { mkdir -p ${cache:h}; print -r -- "$1 $2" >$cache }   # epoch tag

# --- versions
check 'a newer minor is newer' _lazyfleet_newer 0.2.0 0.1.0
check 'versions compare numerically' _lazyfleet_newer 0.10.0 0.9.0
check 'a newer major is newer' _lazyfleet_newer 2.0.0 1.9.9
check 'the same version is not newer' not _lazyfleet_newer 1.2.3 1.2.3
check 'an older version is not newer' not _lazyfleet_newer 0.1.0 0.2.0

reset 0.1.0; check 'reads the installed version' eval '_lazyfleet_version && test "$REPLY" = 0.1.0'
reset v0.1.0; check 'strips a leading v' eval '_lazyfleet_version && test "$REPLY" = 0.1.0'
reset; check 'no VERSION file means no version' not _lazyfleet_version
reset main; check 'a branch install has no version' not _lazyfleet_version

# --- when it is enabled
reset 0.1.0; check 'enabled by default' _lazyfleet_update_enabled
reset; check 'disabled without a VERSION file' not _lazyfleet_update_enabled
reset 0.1.0; LAZYFLEET_UPDATE_CHECK=off
check 'disabled by LAZYFLEET_UPDATE_CHECK=off' not _lazyfleet_update_enabled
reset 0.1.0; mkdir -p ${conf:h}; print 'update_check=off' >$conf
check 'disabled by update_check=off in the config' not _lazyfleet_update_enabled
reset 0.1.0; mkdir -p ${conf:h}; print 'update_check=off' >$conf; LAZYFLEET_UPDATE_CHECK=on
check 'the env var wins over the config' _lazyfleet_update_enabled
unset LAZYFLEET_UPDATE_CHECK

# --- refreshing the cache
reset 0.1.0; _lazyfleet_update_refresh
check 'refresh fetches when there is no cache' retry '[[ -s $cache ]]'
check 'the cache holds the latest tag' gq -E '^[0-9]+ v0\.2\.0$' $cache
check 'refresh asks for the latest release of this repo' gq 'https://github.com/mmolhoek/lazyfleet/releases/latest' $STUB_LOG
check 'refresh asks once' test "$(calls)" = 1

reset 0.1.0; seed $EPOCHSECONDS v0.1.5; _lazyfleet_update_refresh; sleep 0.5
check 'a cache under a day old is not refreshed' test "$(calls)" = 0

reset 0.1.0; seed $(( EPOCHSECONDS - 90000 )) v0.1.5; _lazyfleet_update_refresh
check 'a cache over a day old is refreshed' retry 'gq -E "^[0-9]+ v0\.2\.0$" $cache'

reset 0.1.0; STUB_FAIL=1; export STUB_FAIL; _lazyfleet_update_refresh
check 'a failed lookup is cached, to not retry at once' retry '[[ -s $cache ]]'
check 'a failed lookup caches no tag' gq -E '^[0-9]+ $' $cache
check 'a failed lookup reports no update' not _lazyfleet_update_available

reset 0.1.0; STUB_URL=https://github.com/mmolhoek/lazyfleet/releases; _lazyfleet_update_refresh
check 'no releases yet caches no tag' retry 'gq -E "^[0-9]+ $" $cache'

reset 0.1.0; LAZYFLEET_UPDATE_CHECK=off _lazyfleet_update_refresh; sleep 0.5
check 'refresh does nothing when disabled' test "$(calls)" = 0
check 'refresh writes no cache when disabled' test ! -e $cache

reset 0.1.0; LAZYFLEET_RELEASES_URL=https://example.test/rel _lazyfleet_update_refresh
check 'LAZYFLEET_RELEASES_URL changes where it looks' retry 'gq "https://example.test/rel/latest" $STUB_LOG && [[ -s $cache ]]'

# --- reading the cache
reset 0.1.0; seed $EPOCHSECONDS v0.2.0
check 'a newer cached release is available' eval '_lazyfleet_update_available && test "$REPLY" = v0.2.0'
reset 0.1.0; seed $EPOCHSECONDS v0.1.0
check 'the same cached release is not an update' not _lazyfleet_update_available
reset 0.3.0; seed $EPOCHSECONDS v0.2.0
check 'an older cached release is not an update' not _lazyfleet_update_available
reset 0.1.0
check 'no cache is no update' not _lazyfleet_update_available
reset 0.1.0; seed $(( EPOCHSECONDS - 900000 )) v0.2.0
check 'a stale cache still tells of an update' _lazyfleet_update_available
reset 0.1.0; seed $EPOCHSECONDS garbage
check 'a garbled cache is no update' not _lazyfleet_update_available
reset 0.1.0; seed $EPOCHSECONDS v0.2.0; LAZYFLEET_UPDATE_CHECK=off
check 'no update shown when disabled' not _lazyfleet_update_available
unset LAZYFLEET_UPDATE_CHECK

# --- how to update
reset 0.1.0; print install.sh >$SANDBOX/inst/INSTALLER; _lazyfleet_update_hint
check 'an install.sh install updates by running it again' eval '[[ $REPLY == "curl -fsSL https://raw.githubusercontent.com/mmolhoek/lazyfleet/main/install.sh | sh" ]]'
reset 0.1.0; _lazyfleet_update_hint
check 'anything else gets the releases page' eval '[[ $REPLY == "see https://github.com/mmolhoek/lazyfleet/releases" ]]'

# --- what the person sees
reset 0.1.0; seed $EPOCHSECONDS v0.2.0; print install.sh >$SANDBOX/inst/INSTALLER
msg=$(_lazyfleet_update_notice 2>&1)
check 'the notice names both versions' eval 'gq "lazyfleet v0.2.0 is available (you have v0.1.0)" <<<$msg'
check 'the notice says how to update' eval 'gq "install.sh | sh" <<<$msg'
reset 0.1.0; seed $EPOCHSECONDS v0.1.0
check 'no notice without an update' test -z "$(_lazyfleet_update_notice 2>&1)"
reset 0.1.0; seed $EPOCHSECONDS v0.2.0
check 'the TUI label points out an update' eval '_lazyfleet_ui_label && test "$REPLY" = " lazyfleet · v0.2.0 available "'
reset 0.1.0; seed $EPOCHSECONDS v0.1.0
check 'the TUI label is plain otherwise' eval '_lazyfleet_ui_label && test "$REPLY" = " lazyfleet "'

# --- when it runs: only around the interactive TUI. Stubs live in subshells.
wiring() {  # $1=interactive (0/1), rest: lazyfleet args
  local interactive=$1; shift
  (
    typeset -a calls
    _lazyfleet_ui() { calls+=("ui${*:+ $*}"); return 3 }
    _lazyfleet_update_refresh() { calls+=(refresh) }
    _lazyfleet_update_notice() { calls+=(notice) }
    _lazyfleet_interactive() { return $interactive }
    _lazyfleet_main "$@"
    print -r -- "rc=$? ${calls}"
  )
}
check 'the TUI refreshes before and notifies after' test "$(wiring 0)" = 'rc=3 refresh ui notice'
check 'the windows view does too' test "$(wiring 0 windows)" = 'rc=3 refresh ui -w notice'
check 'the TUI keeps its exit status' eval 'wiring 0 | gq "^rc=3"'
check 'not interactive: no check at all' test "$(wiring 1)" = 'rc=3 ui'
reset 0.1.0
for cmd in help repos ls; do
  check "'lazyfleet $cmd' never checks for updates" eval "_lazyfleet_main $cmd >/dev/null 2>&1; sleep 0.2; test \"\$(calls)\" = 0"
done

# --- lazyfleet update: a check right now
out_of() { out=$("$@" 2>&1); rc=$? }
reset 0.1.0; STUB_URL=https://github.com/mmolhoek/lazyfleet/releases/tag/v0.1.0; out_of _lazyfleet_main update
check 'update says when up to date' eval 'test $rc = 0 && test "$out" = "lazyfleet v0.1.0 is up to date."'
reset 0.1.0; print install.sh >$SANDBOX/inst/INSTALLER; out_of _lazyfleet_main update
check 'update names the new version and how to get it' eval 'test $rc = 0 && gq "lazyfleet v0.2.0 is available (you have v0.1.0). Update: curl .*install.sh | sh" <<<$out'
check 'update asks GitHub once' test "$(calls)" = 1
check 'update refreshes the cache for the TUI' gq -E '^[0-9]+ v0\.2\.0$' $cache
check 'the TUI then shows the update' eval '_lazyfleet_update_available && test "$REPLY" = v0.2.0'
reset 0.1.0; seed $EPOCHSECONDS v0.1.0; out_of _lazyfleet_main update
check 'update ignores a fresh cache' eval 'test "$(calls)" = 1 && gq "v0.2.0 is available" <<<$out'
reset 0.1.0; LAZYFLEET_UPDATE_CHECK=off out_of _lazyfleet_main update
check 'update works when the daily check is off' eval 'test $rc = 0 && gq "v0.2.0 is available" <<<$out'
reset 0.3.0; out_of _lazyfleet_main update
check 'a newer local copy counts as up to date' eval 'test $rc = 0 && gq "is up to date" <<<$out'
reset 0.1.0; STUB_FAIL=1; export STUB_FAIL; out_of _lazyfleet_main update
check 'update fails when GitHub cannot be reached' eval 'test $rc = 1 && gq "could not find the latest release" <<<$out'
check 'a failed update check says nothing is available' eval '! gq "is available" <<<$out'
reset 0.1.0; STUB_URL=https://github.com/mmolhoek/lazyfleet/releases; out_of _lazyfleet_main update
check 'update fails when there is no release yet' eval 'test $rc = 1 && gq "none published yet" <<<$out'
reset; out_of _lazyfleet_main update
check 'update fails without a version' eval 'test $rc = 1 && gq "does not know its version" <<<$out'
check 'update without a version does not call curl' test "$(calls)" = 0
reset main; out_of _lazyfleet_main update
check 'update fails on a branch install' eval 'test $rc = 1 && gq "does not know its version" <<<$out'
check 'the help lists update' eval '_lazyfleet_help | gq "lazyfleet update"'
check 'completion offers update' gq "'update:" $ROOT/_lazyfleet

(( fails )) && { print -P "\n%F{red}$fails failed%f"; exit 1 }
print -P "\n%F{green}all passed%f"
