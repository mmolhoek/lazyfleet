# lazyfleet: The version of this copy, and the daily check for a newer release.
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.

# --- update check ------------------------------------------------------------
# At most once a day, in the background, ask GitHub for the latest release and
# cache the answer; the TUI shows what is cached, so starting it never waits
# for the network. Only a copy that knows its version (a VERSION file, written
# by install.sh) checks: a git checkout does not.
# Turn it off with update_check=off in the config file or LAZYFLEET_UPDATE_CHECK=off.


# REPLY=the version of this copy (X.Y.Z), if it knows one
_lazyfleet_version() {
  local v
  [[ -r $LAZYFLEET_DIR/VERSION ]] || return 1
  v=${${$(<$LAZYFLEET_DIR/VERSION)#v}//[[:space:]]/}
  [[ $v == <->.<->.<-> ]] || return 1
  REPLY=$v
}

# is version $1 newer than version $2? (plain X.Y.Z both)
_lazyfleet_newer() { ! is-at-least $1 $2 }

_lazyfleet_update_enabled() {
  _lazyfleet_version || return 1
  (( $+commands[curl] )) || return 1
  _lazyfleet_flag update_check LAZYFLEET_UPDATE_CHECK on
}

# REPLY=the cache file: "<epoch> <tag>", the tag empty when the lookup failed
_lazyfleet_update_cache() { REPLY=${XDG_CACHE_HOME:-$HOME/.cache}/lazyfleet/latest-release }

# Look up the latest release (GitHub redirects /releases/latest to its tag,
# which spares the API rate limit) and write it to cache file $1
_lazyfleet_update_fetch() {
  local f=$1 url tag= tmp
  url=$(command curl -fsSL --max-time 10 -o /dev/null -w '%{url_effective}' \
    ${LAZYFLEET_RELEASES_URL:-https://github.com/mmolhoek/lazyfleet/releases}/latest 2>/dev/null) && tag=${url:t}
  [[ $tag == v<->.<->.<-> ]] || tag=
  mkdir -p ${f:h} && tmp=$f.$$ && print -r -- "$EPOCHSECONDS $tag" >$tmp && mv -f $tmp $f
}

# Refresh the cache in the background, unless it is under a day old
_lazyfleet_update_refresh() {
  emulate -L zsh
  local f stamp= tag=
  _lazyfleet_update_enabled || return 0
  _lazyfleet_update_cache; f=$REPLY
  [[ -r $f ]] && read -r stamp tag <$f
  [[ $stamp == <-> ]] && (( EPOCHSECONDS - stamp < 86400 )) && return 0
  ( _lazyfleet_update_fetch $f ) &>/dev/null &!
  return 0
}

# REPLY=the cached latest version (vX.Y.Z), if newer than this copy
_lazyfleet_update_available() {
  emulate -L zsh
  local f stamp= tag= cur
  _lazyfleet_update_enabled || return 1
  _lazyfleet_version; cur=$REPLY
  _lazyfleet_update_cache; f=$REPLY
  [[ -r $f ]] && read -r stamp tag <$f
  if [[ $tag == v<->.<->.<-> ]] && _lazyfleet_newer ${tag#v} $cur; then
    REPLY=$tag; return 0
  fi
  REPLY=; return 1
}

# REPLY=how to update this copy, by how it was installed
_lazyfleet_update_hint() {
  if [[ -e $LAZYFLEET_DIR/INSTALLER ]]; then
    REPLY='curl -fsSL https://raw.githubusercontent.com/mmolhoek/lazyfleet/main/install.sh | sh'
  else
    REPLY="see ${LAZYFLEET_RELEASES_URL:-https://github.com/mmolhoek/lazyfleet/releases}"
  fi
}

# Tell (on stderr) that an update is available, and how to get it
_lazyfleet_update_notice() {
  emulate -L zsh
  local tag cur
  _lazyfleet_update_available || return 0
  tag=$REPLY; _lazyfleet_version; cur=$REPLY
  _lazyfleet_update_hint
  print -ru2 -- "lazyfleet $tag is available (you have v$cur). Update: $REPLY"
}

# lazyfleet update [--install] — look for a newer release right now, in the
# foreground, whatever the daily cache or update_check say; the answer
# refreshes the cache. With --install, also install it.
_lazyfleet_update() {
  emulate -L zsh
  local cur tag= stamp= f install=
  case ${1-} in
    ('') ;;
    (--install|-i) install=1 ;;
    (*) _lazyfleet_err "usage: lazyfleet update [--install]"; return 1 ;;
  esac
  (( $# > 1 )) && { _lazyfleet_err "usage: lazyfleet update [--install]"; return 1 }
  _lazyfleet_version || {
    _lazyfleet_err "this copy does not know its version (no VERSION file); a git checkout updates with git pull"
    return 1
  }
  cur=$REPLY
  (( $+commands[curl] )) || { _lazyfleet_err "curl is required to look for updates"; return 1 }
  _lazyfleet_update_cache; f=$REPLY
  _lazyfleet_update_fetch $f
  [[ -r $f ]] && read -r stamp tag <$f
  if [[ -z $tag ]]; then
    _lazyfleet_err "could not find the latest release (offline, or none published yet)"
    return 1
  fi
  if ! _lazyfleet_newer ${tag#v} $cur; then
    print -r -- "lazyfleet v$cur is up to date."
    return 0
  fi
  if [[ -z $install ]]; then
    _lazyfleet_update_hint
    print -r -- "lazyfleet $tag is available (you have v$cur). Update: $REPLY"
    return 0
  fi
  _lazyfleet_update_install $tag $cur
}

# Install release $1 (the current one is $2) by running that release's own
# install.sh on this installation. Only a copy that install.sh put here can be
# replaced this way.
_lazyfleet_update_install() {
  emulate -L zsh
  local tag=$1 cur=$2 tmp url
  if [[ ! -e $LAZYFLEET_DIR/INSTALLER ]]; then
    _lazyfleet_update_hint
    _lazyfleet_err "this copy was not installed by install.sh, so it cannot update itself. $tag is available (you have v$cur): $REPLY"
    return 1
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lazyfleet-update.XXXXXX") || { _lazyfleet_err "could not make a temporary directory"; return 1 }
  {
    url=${LAZYFLEET_INSTALLER_URL:-https://raw.githubusercontent.com/mmolhoek/lazyfleet/$tag/install.sh}
    print -r -- "Installing lazyfleet $tag (you have v$cur)..."
    if ! command curl -fsSL --max-time 30 -o $tmp/install.sh $url 2>/dev/null || [[ ! -s $tmp/install.sh ]]; then
      _lazyfleet_err "could not download the installer for $tag"
      return 1
    fi
    # that release's installer, aimed at this directory and exactly that tag
    env -u LAZYFLEET_SHA256 LAZYFLEET_VERSION=$tag LAZYFLEET_INSTALL_DIR=$LAZYFLEET_DIR sh $tmp/install.sh
  } always {
    rm -rf $tmp
  }
}

# REPLY=what to call this copy: "v1.2.3" for a release, "feat/x (branch)" for
# an install of a branch (install.sh records the branch name as the version).
# Fails when this copy does not know. Only plain name characters are shown,
# since the VERSION file's content ends up on the terminal.
_lazyfleet_version_label() {
  emulate -L zsh
  local v
  if _lazyfleet_version; then REPLY=v$REPLY; return 0; fi
  [[ -r $LAZYFLEET_DIR/VERSION ]] || return 1
  v=${$(<$LAZYFLEET_DIR/VERSION)//[[:space:]]/}
  [[ $v =~ '^[A-Za-z0-9._/-]+$' ]] || return 1
  REPLY="$v (branch)"
}

# REPLY=the version line for the TUI footers: "lazyfleet v1.2.3", followed by
# "update available: v1.2.4" when the cache knows a newer release. Fails when
# this copy does not know its version.
_lazyfleet_version_line() {
  emulate -L zsh
  local label tag
  _lazyfleet_version_label || return 1
  label=$REPLY
  if _lazyfleet_update_available; then
    tag=$REPLY; REPLY="lazyfleet $label · update available: $tag"
  else
    REPLY="lazyfleet $label"
  fi
}
