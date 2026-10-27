#!/usr/bin/env -S zsh -f
# Tests for install.sh. No network: tarballs are served from file:// and the
# "latest release" lookup goes through a curl stub.

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools git
INSTALLER=$ROOT/install.sh
SANDBOX=${$(mktemp -d):A}
trap 'rm -rf $SANDBOX' EXIT
export HOME=$SANDBOX/home
unset XDG_DATA_HOME XDG_CACHE_HOME LAZYFLEET_VERSION LAZYFLEET_SHA256 LAZYFLEET_INSTALL_DIR LAZYFLEET_BIN_DIR LAZYFLEET_REPO
site=$SANDBOX/site
export LAZYFLEET_BASE_URL=file://$site
INST=$HOME/.local/share/lazyfleet
BIN=$HOME/.local/bin
REALCURL=$(command -v curl)


# Publish a tarball for ref $1 (v1.2.3 or a branch), laid out like GitHub's:
# one top-level directory, named after the ref without its v. $2 names a file
# to leave out.
publish() {
  local ref=$1 dir=${${1#v}//\//-} kind=tags    # GitHub names the top directory with / as -
  [[ $ref == v<->.<->.<-> ]] || kind=heads
  local tree=$SANDBOX/tree/lazyfleet-$dir
  rm -rf $tree; mkdir -p $tree $site/mmolhoek/lazyfleet/archive/refs/$kind/${ref:h}
  cp -R $ROOT/lazyfleet.zsh $ROOT/bin $ROOT/_lazyfleet $ROOT/LICENSE $tree/
  [[ -n $2 ]] && rm -rf $tree/$2
  tar -czf $site/mmolhoek/lazyfleet/archive/refs/$kind/$ref.tar.gz -C $SANDBOX/tree lazyfleet-$dir
}

# curl stub: answers the latest-release lookup with $STUB_URL, and hands
# everything else to the real curl
mkdir -p $SANDBOX/stub
cat >$SANDBOX/stub/curl <<STUB
#!/bin/sh
case "\$*" in
  *url_effective*) printf '%s' "\$STUB_URL"; exit \${STUB_RC:-0} ;;
  *) exec $REALCURL "\$@" ;;
esac
STUB
chmod +x $SANDBOX/stub/curl

fresh() { rm -rf $HOME $SANDBOX/site $SANDBOX/tree; mkdir -p $HOME; unset STUB_URL STUB_RC }
# run the installer; leaves its output in $out and its status in $rc
run()   { out=$(sh $INSTALLER "$@" 2>&1); rc=$? }
installed() { [[ -d $INST ]] }
tagurl() { print -rn -- https://github.com/mmolhoek/lazyfleet/releases/tag/$1 }

# --- installing a pinned version
fresh; publish v1.0.0; LAZYFLEET_VERSION=v1.0.0 run
check 'a pinned install succeeds' test $rc = 0
check 'it installs the program files' test -f $INST/lazyfleet.zsh -a -x $INST/bin/lazyfleet -a -f $INST/_lazyfleet
check 'it records the version' test "$(<$INST/VERSION)" = 1.0.0
check 'it marks itself as the installer' test -f $INST/INSTALLER
check 'it installs the agent hook script, executable' test -x $INST/bin/lazyfleet-hook
check 'it links the command' test "$(readlink $BIN/lazyfleet)" = $INST/bin/lazyfleet
check 'the linked command runs' eval 'HOME=$SANDBOX/h2 $BIN/lazyfleet help | gq "git worktrees, each in its own tmux session"'
check 'it says what it installed' eval 'gq "Installed lazyfleet 1.0.0" <<<$out'
check 'it points out a PATH that lacks the bin dir' eval 'gq "is not on your PATH" <<<$out'
check 'it suggests sourcing for completion' eval 'gq "source $INST/lazyfleet.zsh" <<<$out'
check 'it mentions the update check and how to turn it off' eval 'gq "update_check=off" <<<$out'
check 'the installed copy knows its version' eval 'zsh -f -c "source $INST/lazyfleet.zsh; _lazyfleet_version && print -r -- \$REPLY" | gq -x 1.0.0'
check 'the installed copy would update with the installer' eval 'zsh -f -c "source $INST/lazyfleet.zsh; _lazyfleet_update_hint; print -r -- \$REPLY" | gq "install.sh | sh"'
PATH=$BIN:$PATH LAZYFLEET_VERSION=v1.0.0 run
check 'no PATH advice when the bin dir is on the PATH' eval '! gq "is not on your PATH" <<<$out'

# --- the latest release
fresh; publish v1.0.0; out=$(STUB_URL=$(tagurl v1.0.0) PATH=$SANDBOX/stub:$PATH sh $INSTALLER 2>&1); rc=$?
check 'it installs the latest release by default' eval 'test $rc = 0 && test "$(<$INST/VERSION)" = 1.0.0'
fresh; publish v1.0.0; out=$(STUB_URL=https://github.com/mmolhoek/lazyfleet/releases PATH=$SANDBOX/stub:$PATH sh $INSTALLER 2>&1); rc=$?
check 'no release yet fails' test $rc != 0
check 'no release yet suggests LAZYFLEET_VERSION=main' eval 'gq "LAZYFLEET_VERSION=main" <<<$out'
check 'no release yet installs nothing' not installed
fresh; publish v1.0.0; out=$(STUB_URL=x STUB_RC=22 PATH=$SANDBOX/stub:$PATH sh $INSTALLER 2>&1); rc=$?
check 'a failed lookup fails' test $rc != 0
check 'a failed lookup installs nothing' not installed

# --- updating
fresh; publish v1.0.0; publish v1.1.0
LAZYFLEET_VERSION=v1.0.0 run; touch $INST/stale-file
LAZYFLEET_VERSION=v1.1.0 run
check 'updating succeeds' test $rc = 0
check 'updating says so' eval 'gq "Updated lazyfleet 1.0.0 -> 1.1.0" <<<$out'
check 'updating records the new version' test "$(<$INST/VERSION)" = 1.1.0
check 'updating replaces the old files wholesale' test ! -e $INST/stale-file
check 'updating leaves no staging directories' test "$(ls -A $HOME/.local/share)" = lazyfleet
check 'updating keeps the command working' eval 'HOME=$SANDBOX/h2 $BIN/lazyfleet help | gq tmux'
LAZYFLEET_VERSION=v1.1.0 run
check 'installing the same version again works' test $rc = 0
check 'installing the same version again says Installed' eval 'gq "Installed lazyfleet 1.1.0" <<<$out'

# --- a branch
fresh; publish main; LAZYFLEET_VERSION=main run
check 'a branch install succeeds' test $rc = 0
check 'a branch install records the branch' test "$(<$INST/VERSION)" = main
for br in feat/show-version fix/a/b release-1.0 v1.2 under_score; do
  fresh; publish $br; LAZYFLEET_VERSION=$br run
  check "installs the branch '$br'" eval 'test $rc = 0 && test "$(<$INST/VERSION)" = "$br" && test -f $INST/lazyfleet.zsh'
  check "'$br' installs a working command" eval 'HOME=$SANDBOX/h2 $BIN/lazyfleet help | gq tmux'
done
fresh; publish v1.0.0; publish feat/x; LAZYFLEET_VERSION=feat/x run
check 'a branch install records itself as the installer' test -f $INST/INSTALLER
check 'a branch install can be updated to a release' eval 'LAZYFLEET_VERSION=v1.0.0 run; test $rc = 0 && test "$(<$INST/VERSION)" = 1.0.0'

# --- bad input: refused by the validation itself, before any download
for bad in '../etc' 'a b' 'v1.0.0;touch$IFS/tmp/pwned' '/abs' 'a//b' 'a/../b' 'a/..' '..' 'feat/' '-x' 'a/-x' '.hidden' 'a/.hidden' 'x..y' 'x.lock' 'x.' 'a?b' 'a*b' 'a~b' 'a:b' 'a\\b'; do
  fresh; publish v1.0.0; LAZYFLEET_VERSION=$bad run
  check "rejects the version '$bad' as invalid" eval 'test $rc != 0 && gq "invalid version" <<<$out'
  check "'$bad' installs nothing" not installed
done
fresh; publish v1.0.0; LAZYFLEET_VERSION=v1.2.3-rc1 run
check 'a prerelease-style tag is not a release: it fails at the download' eval 'test $rc != 0 && gq "download failed" <<<$out'
check 'and installs nothing' not installed
fresh; publish v1.0.0; LAZYFLEET_REPO='a/b;c' LAZYFLEET_VERSION=v1.0.0 run
check 'rejects a strange repository' test $rc != 0
fresh; run frobnicate
check 'rejects an unknown command' test $rc != 0

# --- the download
fresh; LAZYFLEET_VERSION=v9.9.9 run
check 'a missing download fails' test $rc != 0
check 'a missing download installs nothing' not installed
fresh; publish v1.0.0 bin
LAZYFLEET_VERSION=v1.0.0 run
check 'a tarball that is not lazyfleet is refused' test $rc != 0
check 'a refused tarball installs nothing' not installed

# --- checksum
fresh; publish v1.0.0
sum=$(sha256sum $site/mmolhoek/lazyfleet/archive/refs/tags/v1.0.0.tar.gz | cut -d' ' -f1)
LAZYFLEET_VERSION=v1.0.0 LAZYFLEET_SHA256=$sum run
check 'a matching sha256 installs' test $rc = 0
fresh; publish v1.0.0
LAZYFLEET_VERSION=v1.0.0 LAZYFLEET_SHA256=${(l:64::0:)} run
check 'a wrong sha256 fails' test $rc != 0
check 'a wrong sha256 installs nothing' not installed

# --- never clobber what is not ours
fresh; publish v1.0.0; mkdir -p $BIN; print mine >$BIN/lazyfleet
LAZYFLEET_VERSION=v1.0.0 run
check 'refuses to replace a regular file' test $rc != 0
check 'the file is left alone' test "$(<$BIN/lazyfleet)" = mine
check 'nothing is installed beside it' not installed
fresh; publish v1.0.0; mkdir -p $BIN; ln -s /usr/bin/true $BIN/lazyfleet
LAZYFLEET_VERSION=v1.0.0 run
check 'refuses to replace a link to something else' test $rc != 0
check 'the other link is left alone' test "$(readlink $BIN/lazyfleet)" = /usr/bin/true
fresh; publish v1.0.0; mkdir -p $INST; print precious >$INST/notes
LAZYFLEET_VERSION=v1.0.0 run
check 'refuses an install dir it did not make' test $rc != 0
check 'that directory is left alone' test "$(<$INST/notes)" = precious
fresh; publish v1.0.0; LAZYFLEET_INSTALL_DIR=$HOME LAZYFLEET_VERSION=v1.0.0 run
check 'refuses HOME as the install dir' test $rc != 0
fresh; publish v1.0.0; LAZYFLEET_INSTALL_DIR=/ LAZYFLEET_VERSION=v1.0.0 run
check 'refuses / as the install dir' test $rc != 0

# --- custom locations
fresh; publish v1.0.0
LAZYFLEET_INSTALL_DIR=$SANDBOX/opt/lf LAZYFLEET_BIN_DIR=$SANDBOX/opt/bin LAZYFLEET_VERSION=v1.0.0 run
check 'honours LAZYFLEET_INSTALL_DIR and LAZYFLEET_BIN_DIR' test -x $SANDBOX/opt/bin/lazyfleet -a -f $SANDBOX/opt/lf/VERSION
fresh; publish v1.0.0; XDG_DATA_HOME=$SANDBOX/xdg LAZYFLEET_VERSION=v1.0.0 run
check 'honours XDG_DATA_HOME' test -f $SANDBOX/xdg/lazyfleet/VERSION

# --- dependency warnings: a PATH holding only what the installer itself needs
tb=$SANDBOX/toolbox; mkdir -p $tb
for t in sh curl tar gzip cat mkdir cp mv rm ln readlink dirname mktemp awk grep cut sha256sum sed ls; do ln -sf $(command -v $t) $tb/$t; done
fresh; publish v1.0.0; out=$(PATH=$tb LAZYFLEET_VERSION=v1.0.0 sh $INSTALLER 2>&1); rc=$?
check 'it installs even when tools are missing' test $rc = 0
check 'it warns about the missing tools' eval 'gq "missing: zsh git tmux fzf" <<<$out'
mkdir -p $SANDBOX/oldfzf $SANDBOX/newfzf
print -r -- $'#!/bin/sh\necho "0.44.1 (debian)"' >$SANDBOX/oldfzf/fzf
print -r -- $'#!/bin/sh\necho "0.74.0 (devel)"' >$SANDBOX/newfzf/fzf
chmod +x $SANDBOX/oldfzf/fzf $SANDBOX/newfzf/fzf
fresh; publish v1.0.0; out=$(PATH=$SANDBOX/oldfzf:$tb LAZYFLEET_VERSION=v1.0.0 sh $INSTALLER 2>&1)
check 'it warns about an fzf that is too old' eval 'gq "fzf 0.44.1 is too old" <<<$out'
fresh; publish v1.0.0; out=$(PATH=$SANDBOX/newfzf:$tb LAZYFLEET_VERSION=v1.0.0 sh $INSTALLER 2>&1)
check 'it does not warn about a recent fzf' eval '! gq "too old" <<<$out'

# --- uninstalling
fresh; publish v1.0.0; LAZYFLEET_VERSION=v1.0.0 run
mkdir -p $HOME/.config/lazyfleet; print repos >$HOME/.config/lazyfleet/repos; print other >$BIN/other-tool
run uninstall
check 'uninstall succeeds' test $rc = 0
check 'uninstall removes the files' not installed
check 'uninstall removes the command' test ! -e $BIN/lazyfleet -a ! -L $BIN/lazyfleet
check 'uninstall leaves other commands alone' test -f $BIN/other-tool
check 'uninstall leaves the settings alone' test -f $HOME/.config/lazyfleet/repos
run uninstall
check 'uninstalling twice fails cleanly' test $rc != 0
fresh; mkdir -p $INST; print precious >$INST/notes; run uninstall
check 'uninstall refuses a directory it did not make' test $rc != 0
check 'that directory is left alone by uninstall' test "$(<$INST/notes)" = precious
fresh; publish v1.0.0; LAZYFLEET_VERSION=v1.0.0 run; rm $BIN/lazyfleet; ln -s /usr/bin/true $BIN/lazyfleet; run uninstall
check 'uninstall keeps a link that is not ours' test "$(readlink $BIN/lazyfleet)" = /usr/bin/true

# --- running through a pipe, as in `curl ... | sh`
fresh; publish v1.0.0
out=$(LAZYFLEET_VERSION=v1.0.0 sh <$INSTALLER 2>&1); rc=$?
check 'it installs when piped into sh' eval 'test $rc = 0 && test -f $INST/VERSION'
out=$(sh -s -- uninstall <$INSTALLER 2>&1); rc=$?
check 'it takes arguments through sh -s --' eval 'test $rc = 0 && test ! -d $INST'
fresh; publish v1.0.0
out=$(sed '$d' $INSTALLER | LAZYFLEET_VERSION=v1.0.0 sh 2>&1); rc=$?
check 'a truncated download does nothing' eval 'test $rc = 0 && test ! -d $INST'
check 'the last line is the call to main' test "$(tail -n 1 $INSTALLER)" = 'main "$@"'
check 'it stops on errors and unset variables' gq -x 'set -eu' $INSTALLER
if (( $+commands[bash] )); then
  fresh; publish v1.0.0; out=$(LAZYFLEET_VERSION=v1.0.0 bash $INSTALLER 2>&1); rc=$?
  check 'it also runs under bash' eval 'test $rc = 0 && test -f $INST/VERSION'
fi

finish
