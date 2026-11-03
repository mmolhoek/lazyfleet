# lazyfleet: The split between the list and the Details pane, remembered per terminal width.
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.
#
# < and > move the divider, 5% at a time. The Worktrees and the Windows view
# each have a split of their own, kept per width of the terminal: that is what
# tells a laptop's screen from a large monitor's (lazyfleet cannot see which
# monitor it is on). When the terminal is resized (moved to the other screen)
# the split saved for the new width comes back. They are kept in
# $XDG_STATE_HOME/lazyfleet/split, as lines "view width percent" (view: w or t).

typeset -gA _LAZYFLEET_SPLIT_DEFAULT=(w 50 t 70)
typeset -g _LAZYFLEET_SPLIT_STEP=5 _LAZYFLEET_SPLIT_MIN=20 _LAZYFLEET_SPLIT_MAX=80

_lazyfleet_split_file() { REPLY=${XDG_STATE_HOME:-$HOME/.local/state}/lazyfleet/split }

# REPLY=the Details pane's share, in percent, for view $1 (w or t) in a
# terminal $2 columns wide: the saved one, else the view's default
_lazyfleet_split_get() {
  local line f
  _lazyfleet_split_file; f=$REPLY
  REPLY=$_LAZYFLEET_SPLIT_DEFAULT[$1]
  [[ -r $f && $2 == <1-> ]] || return 0
  for line in ${(f)"$(<$f)"}; do
    [[ $line == "$1 $2 "<1-> ]] || continue
    (( ${line##* } >= _LAZYFLEET_SPLIT_MIN && ${line##* } <= _LAZYFLEET_SPLIT_MAX )) && REPLY=${line##* }
  done
  return 0
}

# Save $3 percent as view $1's split at width $2 (the 50 latest are kept)
_lazyfleet_split_set() {
  local f
  local -a keep
  [[ $1 == [wt] && $2 == <1-> && $3 == <1-> ]] || return 1
  _lazyfleet_split_file; f=$REPLY
  mkdir -p ${f:h} 2>/dev/null || return 1
  [[ -r $f ]] && keep=(${(f)"$(<$f)"})
  keep=(${keep:#"$1 $2 "*} "$1 $2 $3")
  # (only when there are more: zsh gives nothing for -50 past the start)
  (( $#keep > 50 )) && keep=(${keep[-50,-1]})
  print -rl -- $keep >|$f.$$ && mv -f $f.$$ $f
}

# REPLY=the terminal's width: fzf's (in a key handler), else the terminal's
_lazyfleet_split_width() {
  local -a size
  if [[ $FZF_COLUMNS == <1-> ]]; then REPLY=$FZF_COLUMNS; return 0; fi
  size=(${=$(stty size </dev/tty 2>/dev/null)})
  REPLY=${size[2]:-${COLUMNS:-80}}
}

# REPLY=fzf's --preview-window for view $1 (w or t) at width $2
_lazyfleet_split_pw() { _lazyfleet_split_get $1 $2; REPLY="right,$REPLY%" }

# REPLY=the current view: w (Worktrees) or t (Windows)
_lazyfleet_split_view() { _lazyfleet_key_label; [[ $REPLY == Windows ]] && REPLY=t || REPLY=w }

# < and >: the Details pane wider (the divider moves left) or narrower; saved
_lazyfleet_split_key() {
  local v w pct
  _lazyfleet_split_view; v=$REPLY
  _lazyfleet_split_width; w=$REPLY
  _lazyfleet_split_get $v $w; pct=$REPLY
  if [[ $FZF_KEY == '<' ]]; then (( pct += _LAZYFLEET_SPLIT_STEP )); else (( pct -= _LAZYFLEET_SPLIT_STEP )); fi
  (( pct < _LAZYFLEET_SPLIT_MIN )) && pct=$_LAZYFLEET_SPLIT_MIN
  (( pct > _LAZYFLEET_SPLIT_MAX )) && pct=$_LAZYFLEET_SPLIT_MAX
  _lazyfleet_split_set $v $w $pct
  print -r -- "change-preview-window(right,$pct%)"
}

# fzf's resize event: the split saved for the new width (or the default)
_lazyfleet_split_resized() {
  local v
  _lazyfleet_split_view; v=$REPLY
  _lazyfleet_split_width
  _lazyfleet_split_pw $v $REPLY
  print -r -- "change-preview-window($REPLY)"
}
