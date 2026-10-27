#!/usr/bin/env -S zsh -f
# Tests for the update check (no network: curl is a stub).

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools git
SANDBOX=${$(mktemp -d):A}
trap 'rm -rf $SANDBOX' EXIT
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg
unset XDG_CACHE_HOME LAZYFLEET_UPDATE_CHECK LAZYFLEET_RELEASES_URL
export TMPDIR=$SANDBOX/tmp
mkdir -p $HOME $XDG_CONFIG_HOME $SANDBOX/stub $SANDBOX/inst $TMPDIR

# curl stub: logs its arguments, fails when STUB_FAIL is set, else answers with
# the url a redirect to the latest release would end at
cat >$SANDBOX/stub/curl <<'STUB'
#!/bin/sh
echo "$*" >>"$STUB_LOG"
[ -n "$STUB_FAIL" ] && exit 22
case "$*" in
  *install.sh*)
    [ -n "$STUB_NO_INSTALLER" ] && exit 22
    out=
    while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
    if [ -n "$STUB_EMPTY" ]; then : >"$out"; else cp "$STUB_INSTALLER" "$out"; fi
    ;;
  *) printf '%s' "$STUB_URL" ;;
esac
STUB
chmod +x $SANDBOX/stub/curl
export STUB_LOG=$SANDBOX/curl.log
export STUB_INSTALLER=$SANDBOX/fake-install.sh INSTALLER_LOG=$SANDBOX/installer.log
# the installer a release would ship: it only records how it was run
cat >$STUB_INSTALLER <<'FAKE'
#!/bin/sh
echo "version=$LAZYFLEET_VERSION dir=$LAZYFLEET_INSTALL_DIR sha=${LAZYFLEET_SHA256-unset} args=$*" >>"$INSTALLER_LOG"
echo "fake installer ran"
exit ${INSTALLER_RC:-0}
FAKE
path=($SANDBOX/stub $path)

source $ROOT/lazyfleet.zsh
LAZYFLEET_DIR=$SANDBOX/inst
cache=$HOME/.cache/lazyfleet/latest-release
conf=$XDG_CONFIG_HOME/lazyfleet/config

calls() { [[ -e $STUB_LOG ]] && wc -l <$STUB_LOG | tr -d ' ' || print 0 }
# fresh state: version $1 installed, no cache, no config, no curl calls
reset() {
  rm -rf $HOME/.cache $XDG_CONFIG_HOME/lazyfleet $STUB_LOG $INSTALLER_LOG $SANDBOX/inst/INSTALLER
  unset STUB_FAIL STUB_NO_INSTALLER STUB_EMPTY INSTALLER_RC LAZYFLEET_UPDATE_CHECK LAZYFLEET_INSTALLER_URL LAZYFLEET_SHA256
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

# --- lazyfleet update --install
installer_log() { [[ -r $INSTALLER_LOG ]] && cat $INSTALLER_LOG }
reset 0.1.0; print install.sh >$SANDBOX/inst/INSTALLER; out_of _lazyfleet_main update --install
check 'update --install runs the installer' eval 'test $rc = 0 && gq "fake installer ran" <<<$out'
check 'it installs exactly the release it found' eval 'installer_log | gq "version=v0.2.0 "'
check 'it installs into this directory' eval 'installer_log | gq "dir=$SANDBOX/inst "'
check 'it runs the installer once' test "$(installer_log | wc -l | tr -d " ")" = 1
check 'it says what it is doing' eval 'gq "Installing lazyfleet v0.2.0 (you have v0.1.0)" <<<$out'
check 'it fetches the installer of that release' gq "raw.githubusercontent.com/mmolhoek/lazyfleet/v0.2.0/install.sh" $STUB_LOG
reset 0.1.0; print install.sh >$SANDBOX/inst/INSTALLER; out_of _lazyfleet_main update -i
check '-i is short for --install' eval 'installer_log | gq "version=v0.2.0 "'
reset 0.1.0; print install.sh >$SANDBOX/inst/INSTALLER; LAZYFLEET_SHA256=abc out_of _lazyfleet_main update --install
check 'a checksum meant for another version is not passed on' eval 'installer_log | gq "sha=unset"'
reset 0.1.0; print install.sh >$SANDBOX/inst/INSTALLER; LAZYFLEET_INSTALLER_URL=https://example.test/i.sh out_of _lazyfleet_main update --install
check 'LAZYFLEET_INSTALLER_URL moves the download' gq "example.test/i.sh" $STUB_LOG
reset 0.3.0; print install.sh >$SANDBOX/inst/INSTALLER; out_of _lazyfleet_main update --install
check 'up to date: nothing is installed' eval 'test $rc = 0 && gq "is up to date" <<<$out && test -z "$(installer_log)"'
reset 0.1.0; out_of _lazyfleet_main update --install
check 'a copy not put there by install.sh is not touched' eval 'test $rc = 1 && gq "not installed by install.sh" <<<$out && test -z "$(installer_log)"'
check 'it points to the way to update that copy' eval 'gq "releases" <<<$out'
reset 0.1.0; print install.sh >$SANDBOX/inst/INSTALLER; STUB_NO_INSTALLER=1 out_of _lazyfleet_main update --install
check 'a failed installer download fails' eval 'test $rc = 1 && gq "could not download the installer" <<<$out'
check 'a failed download runs nothing' eval 'test -z "$(installer_log)"'
reset 0.1.0; print install.sh >$SANDBOX/inst/INSTALLER; STUB_EMPTY=1 out_of _lazyfleet_main update --install
check 'an empty download is not run' eval 'test $rc = 1 && gq "could not download the installer" <<<$out'
reset 0.1.0; print install.sh >$SANDBOX/inst/INSTALLER; INSTALLER_RC=3 out_of _lazyfleet_main update --install
check "the installer's failure is the exit status" test $rc = 3
reset 0.1.0; print install.sh >$SANDBOX/inst/INSTALLER; out_of _lazyfleet_main update --install
check 'the downloaded installer is removed again' eval 'test -z "$(print -l $TMPDIR/lazyfleet-update.*(N))"'
reset 0.1.0; print install.sh >$SANDBOX/inst/INSTALLER; STUB_FAIL=1; export STUB_FAIL; out_of _lazyfleet_main update --install
check 'offline: nothing is installed' eval 'test $rc = 1 && test -z "$(installer_log)"'
unset STUB_FAIL
reset 0.1.0; print install.sh >$SANDBOX/inst/INSTALLER; out_of _lazyfleet_main update --bogus
check 'an unknown option is refused' eval 'test $rc = 1 && gq "usage: lazyfleet update" <<<$out && test "$(calls)" = 0'
out_of _lazyfleet_main update --install extra
check 'extra arguments are refused' eval 'test $rc = 1 && gq "usage: lazyfleet update" <<<$out'
reset; print install.sh >$SANDBOX/inst/INSTALLER; out_of _lazyfleet_main update --install
check '--install without a version fails like update does' eval 'test $rc = 1 && gq "does not know its version" <<<$out'
check 'the help lists --install' eval '_lazyfleet_help | gq -- "update \[--install\]"'
check 'completion offers --install' gq -- "--install" $ROOT/_lazyfleet

# --- showing the version: footers, help, `lazyfleet version`
reset 0.1.0
check 'the version line is the version' eval '_lazyfleet_version_line && test "$REPLY" = "lazyfleet v0.1.0"'
reset 0.1.0; seed $EPOCHSECONDS v0.2.0
check 'the version line names an update' eval '_lazyfleet_version_line && test "$REPLY" = "lazyfleet v0.1.0 · update available: v0.2.0"'
reset 0.1.0; seed $EPOCHSECONDS v0.2.0; LAZYFLEET_UPDATE_CHECK=off
check 'the version line stays quiet about updates when they are off' eval '_lazyfleet_version_line && test "$REPLY" = "lazyfleet v0.1.0"'
unset LAZYFLEET_UPDATE_CHECK
reset; check 'there is no version line without a version' not _lazyfleet_version_line

# an install of a branch: its name stands in for the version, and it never checks for updates
reset 0.1.0;   check 'a release is labelled v1.2.3' eval '_lazyfleet_version_label && test "$REPLY" = v0.1.0'
reset feat/x;  check 'a branch install is labelled with the branch' eval '_lazyfleet_version_label && test "$REPLY" = "feat/x (branch)"'
reset;         check 'a checkout has no label' not _lazyfleet_version_label
reset $'x\e[31m'; check 'a VERSION with control characters has no label' not _lazyfleet_version_label
reset 'a b';   check 'a VERSION with spaces inside has no label' not _lazyfleet_version_label
reset feat/x;  check 'the version line names the branch' eval '_lazyfleet_version_line && test "$REPLY" = "lazyfleet feat/x (branch)"'
reset feat/x; seed $EPOCHSECONDS v9.9.9
check 'a branch install is never told of an update' eval '_lazyfleet_version_line && test "$REPLY" = "lazyfleet feat/x (branch)"'
reset feat/x; check 'help names the branch' eval '_lazyfleet_help | head -1 | gq -x "lazyfleet feat/x (branch) — git worktrees, each in its own tmux session"'
reset feat/x; check 'lazyfleet version names the branch' test "$(_lazyfleet_main version)" = 'lazyfleet feat/x (branch)'
reset feat/x; _lazyfleet_update_refresh; sleep 0.3
check 'a branch install never calls curl' test "$(calls)" = 0

# the footers are globals: each case runs in a subshell
footer_cases() {
  local wt0=$_LAZYFLEET_FOOTER_WT win0=$_LAZYFLEET_FOOTER_WIN
  reset 0.1.0
  local tail=$'\n'"lazyfleet v0.1.0"
  ( _lazyfleet_footers
    [[ $_LAZYFLEET_FOOTER_WT == $wt0$tail && $_LAZYFLEET_FOOTER_WIN == $win0$tail ]] ) && print ok-all || print no-all
  ( _lazyfleet_footers; _lazyfleet_footers; _lazyfleet_footers
    [[ $_LAZYFLEET_FOOTER_WT == $wt0$'\n'"lazyfleet v0.1.0" ]] ) && print ok-once || print no-once
  reset
  ( _lazyfleet_footers
    [[ $_LAZYFLEET_FOOTER_WT == $wt0 && $_LAZYFLEET_FOOTER_WIN == $win0 ]] ) && print ok-none || print no-none
}
res=$(footer_cases)
check 'every footer gets the version line' gq -x ok-all <<<$res
check 'doing it again adds nothing' gq -x ok-once <<<$res
check 'without a version the footers are untouched' gq -x ok-none <<<$res

reset 0.1.0; seed $EPOCHSECONDS v0.2.0
keys=$( FZF_KEY=tab FZF_LIST_LABEL=" Worktrees " _lazyfleet_key w $SANDBOX/none 2>&1 )
check 'the key handler uses the footers with the version' eval 'tr "\n" " " <<<$keys | gq "change-footer(.*lazyfleet v0.1.0 · update available: v0.2.0)"'

# the TUI start: a stub fzf records its arguments
cat >$SANDBOX/stub/fzf <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >"$FZF_ARGS"
exit 1
STUB
chmod +x $SANDBOX/stub/fzf
rehash
export FZF_ARGS=$SANDBOX/fzf.args
reset 0.1.0; seed $EPOCHSECONDS v0.2.0; rm -f $FZF_ARGS
( export LAZYFLEET_TMUX="tmux -L lf-update-test" TMUX_TMPDIR=$SANDBOX; unset TMUX; _lazyfleet_ui </dev/null >/dev/null 2>&1 )
check 'the TUI footer carries the version and the update' eval 'gq "lazyfleet v0.1.0 · update available: v0.2.0" $FZF_ARGS'
check 'the TUI title points out the update' eval 'gq -x " lazyfleet · v0.2.0 available " $FZF_ARGS'
reset; rm -f $FZF_ARGS
( export LAZYFLEET_TMUX="tmux -L lf-update-test" TMUX_TMPDIR=$SANDBOX; unset TMUX; _lazyfleet_ui </dev/null >/dev/null 2>&1 )
check 'a checkout shows no version in the footer' eval '! gq "lazyfleet v" $FZF_ARGS'

reset 0.1.0
check 'help names the version' eval '_lazyfleet_help | head -1 | gq -x "lazyfleet v0.1.0 — git worktrees, each in its own tmux session"'
check 'help mentions no update when current' eval '! _lazyfleet_help | gq "Update available"'
reset 0.1.0; seed $EPOCHSECONDS v0.2.0; print install.sh >$SANDBOX/inst/INSTALLER
check 'help tells of an update and how to get it' eval '_lazyfleet_help | tail -1 | gq "Update available: v0.2.0. Update: curl .*install.sh | sh"'
reset
check 'help of a checkout is unchanged' eval '_lazyfleet_help | head -1 | gq -x "lazyfleet — git worktrees, each in its own tmux session"'
reset 0.1.0
for flag in version --version -V; do
  check "'lazyfleet $flag' prints the version" test "$(_lazyfleet_main $flag)" = 'lazyfleet v0.1.0'
done
reset; check 'a checkout says its version is unknown' eval '_lazyfleet_main version | gq "unknown version"'
reset 0.1.0; _lazyfleet_main version >/dev/null; sleep 0.2
check 'showing the version never uses the network' test "$(calls)" = 0
check 'completion offers version' gq "'version:" $ROOT/_lazyfleet

finish
