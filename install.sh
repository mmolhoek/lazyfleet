#!/bin/sh
# lazyfleet installer.
#
#   curl -fsSL https://raw.githubusercontent.com/mmolhoek/lazyfleet/main/install.sh | sh
#
# Installs the latest release into ~/.local/share/lazyfleet and links the
# command as ~/.local/bin/lazyfleet. It never edits your shell's rc files.
#
#   sh install.sh              install or update to the latest release
#   sh install.sh uninstall    remove what this script installed
#
# Through a pipe, pass arguments like this:  ... | sh -s -- uninstall
#
# Environment:
#   LAZYFLEET_VERSION      install this tag (v1.2.3) or branch (main) instead
#   LAZYFLEET_SHA256       fail unless the downloaded tarball has this sha256
#   LAZYFLEET_INSTALL_DIR  where the files go   (default ~/.local/share/lazyfleet)
#   LAZYFLEET_BIN_DIR      where the command goes (default ~/.local/bin)
#   LAZYFLEET_REPO         owner/name on GitHub (default mmolhoek/lazyfleet)
#   LAZYFLEET_BASE_URL     default https://github.com
#
# Everything happens inside main, called on the last line, so a download that
# is cut short runs nothing.

set -eu

MIN_FZF=0.58   # first fzf with --style

say()  { printf '%s\n' "$*"; }
warn() { printf 'lazyfleet: warning: %s\n' "$*" >&2; }
die()  { printf 'lazyfleet: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

settings() {
  REPO=${LAZYFLEET_REPO:-mmolhoek/lazyfleet}
  BASE_URL=${LAZYFLEET_BASE_URL:-https://github.com}
  INSTALL_DIR=${LAZYFLEET_INSTALL_DIR:-${XDG_DATA_HOME:-${HOME:?HOME is not set}/.local/share}/lazyfleet}
  BIN_DIR=${LAZYFLEET_BIN_DIR:-${HOME:?HOME is not set}/.local/bin}
  printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || die "invalid repository '$REPO'"
  case $INSTALL_DIR in
    ''|/|"$HOME"|"$HOME"/) die "refusing to use '$INSTALL_DIR' as the install directory" ;;
  esac
}

# is dotted version $1 >= $2?
version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, ".")
    for (i = 1; i <= (n > m ? n : m); i++) {
      if (x[i] + 0 > y[i] + 0) exit 0
      if (x[i] + 0 < y[i] + 0) exit 1
    }
    exit 0 }'
}

sha256_of() {
  if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
  elif have shasum; then shasum -a 256 "$1" | cut -d' ' -f1
  else die "need sha256sum or shasum to verify the download"; fi
}

# The tag of the latest release. GitHub redirects /releases/latest to the
# tag's page, which spares the API rate limit and needs no JSON parsing.
latest_tag() {
  url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$BASE_URL/$REPO/releases/latest") || return 1
  tag=${url##*/}
  printf '%s' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || return 1
  printf '%s\n' "$tag"
}

# Print the tarball url for ref $1 (a vX.Y.Z tag, or a branch name)
tarball_url() {
  if printf '%s' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf '%s/%s/archive/refs/tags/%s.tar.gz\n' "$BASE_URL" "$REPO" "$1"
  elif printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+$'; then
    printf '%s/%s/archive/refs/heads/%s.tar.gz\n' "$BASE_URL" "$REPO" "$1"
  else
    die "invalid version '$1' (use a tag like v1.2.3 or a branch name)"
  fi
}

check_deps() {
  missing=
  for c in zsh git tmux fzf; do have "$c" || missing="$missing $c"; done
  if [ -n "$missing" ]; then
    warn "missing:$missing. lazyfleet needs zsh, git, tmux and fzf."
    warn "  macOS: brew install$missing    Debian/Ubuntu: sudo apt install$missing"
  fi
  if have fzf; then
    v=$(fzf --version 2>/dev/null | awk '{ print $1; exit }')
    if [ -n "$v" ] && ! version_ge "$v" "$MIN_FZF"; then
      warn "fzf $v is too old: lazyfleet needs $MIN_FZF or newer (https://github.com/junegunn/fzf)"
    fi
  fi
}

# Die unless the command link is absent or already ours: never replace a
# file or a link that is not
check_link() {
  link=$BIN_DIR/lazyfleet
  if [ -L "$link" ]; then
    [ "$(readlink "$link")" = "$INSTALL_DIR/bin/lazyfleet" ] || die "$link already points elsewhere ($(readlink "$link")); remove it first"
  elif [ -e "$link" ]; then
    die "$link already exists and is not a link; remove it first"
  fi
}

link_command() {
  check_link
  mkdir -p "$BIN_DIR"
  ln -sfn "$INSTALL_DIR/bin/lazyfleet" "$BIN_DIR/lazyfleet"
}

install() {
  have curl || die "curl is required"
  have tar || die "tar is required"
  ref=${LAZYFLEET_VERSION:-}
  if [ -z "$ref" ]; then
    say "Looking up the latest release..."
    ref=$(latest_tag) || die "could not find a release. Try LAZYFLEET_VERSION=main to install the development version."
  fi
  url=$(tarball_url "$ref")
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT INT TERM

  say "Downloading lazyfleet $ref..."
  curl -fsSL --retry 3 -o "$work/src.tar.gz" "$url" || die "download failed: $url"
  if [ -n "${LAZYFLEET_SHA256:-}" ]; then
    [ "$(sha256_of "$work/src.tar.gz")" = "$LAZYFLEET_SHA256" ] || die "sha256 of the download does not match LAZYFLEET_SHA256"
  fi
  mkdir "$work/src"
  tar -xzf "$work/src.tar.gz" -C "$work/src" --strip-components=1 || die "could not unpack the download"
  for f in lazyfleet.zsh bin/lazyfleet _lazyfleet; do
    [ -f "$work/src/$f" ] || die "the download is not lazyfleet (no $f)"
  done

  # check the link before anything is replaced, then swap the install in with
  # renames so a failure leaves the old one working
  check_link
  if [ -e "$INSTALL_DIR" ] && [ ! -f "$INSTALL_DIR/INSTALLER" ]; then
    die "$INSTALL_DIR exists and was not installed by install.sh; move it away or set LAZYFLEET_INSTALL_DIR"
  fi
  parent=$(dirname "$INSTALL_DIR")
  mkdir -p "$parent"
  stage=$INSTALL_DIR.new.$$
  rm -rf "$stage"; mkdir "$stage"
  cp -R "$work/src/lazyfleet.zsh" "$work/src/bin" "$work/src/_lazyfleet" "$stage/"
  [ -f "$work/src/LICENSE" ] && cp "$work/src/LICENSE" "$stage/"
  printf '%s\n' "${ref#v}" >"$stage/VERSION"
  printf 'install.sh\n' >"$stage/INSTALLER"
  old=
  if [ -e "$INSTALL_DIR" ]; then
    old=$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || true)
    mv "$INSTALL_DIR" "$INSTALL_DIR.old.$$"
  fi
  mv "$stage" "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR.old.$$"
  link_command

  if [ -n "$old" ] && [ "$old" != "${ref#v}" ]; then say "Updated lazyfleet $old -> ${ref#v}."
  else say "Installed lazyfleet ${ref#v}."; fi
  say "  files:   $INSTALL_DIR"
  say "  command: $BIN_DIR/lazyfleet"
  check_deps
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) say ""; say "$BIN_DIR is not on your PATH. Add this to your shell's rc file:"
       say "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
  esac
  say ""
  say "For zsh completion, add this to ~/.zshrc instead of the PATH line:"
  say "  source $INSTALL_DIR/lazyfleet.zsh"
  say "lazyfleet looks for a newer release once a day; turn that off with update_check=off in"
  say "~/.config/lazyfleet/config (or LAZYFLEET_UPDATE_CHECK=off)."
}

uninstall() {
  # only remove a directory this script made
  [ -f "$INSTALL_DIR/INSTALLER" ] && [ -f "$INSTALL_DIR/lazyfleet.zsh" ] ||
    die "$INSTALL_DIR was not installed by install.sh; nothing removed"
  link=$BIN_DIR/lazyfleet
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$INSTALL_DIR/bin/lazyfleet" ]; then rm -f "$link"; fi
  rm -rf "$INSTALL_DIR"
  say "Removed lazyfleet. Your repos and settings in ~/.config/lazyfleet are untouched."
}

main() {
  settings
  case ${1:-install} in
    install) install ;;
    uninstall) uninstall ;;
    *) die "unknown command '$1' (use: install, uninstall)" ;;
  esac
}

main "$@"
