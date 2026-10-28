#!/usr/bin/env -S zsh -f
# The Windows view's preview of a tmux window. When the window's active pane is
# the very pane lazyfleet draws in, a capture of it contains the preview, which
# contains the capture, and the live redraw never settles: starting lazyfleet
# inside tmux used to fill the preview with ever deeper copies of itself.

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools tmux
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX TMPDIR=$SANDBOX/tmp SHELL=/bin/sh
mkdir -p $TMPDIR
use_tmux winprev
source $ROOT/lazyfleet.zsh
trap 'tmux_cleanup; rm -rf $SANDBOX' EXIT

# --- _lazyfleet_own_pane: is pane id $1 the one we run in?
(
  TMUX_PANE=%3
  check 'own pane: the pane lazyfleet runs in' _lazyfleet_own_pane %3
  check 'own pane: another pane is not' not _lazyfleet_own_pane %4
  check 'own pane: an id that only starts like ours is not' not _lazyfleet_own_pane %30
  check 'own pane: an empty id is not' not _lazyfleet_own_pane ''
)
(
  unset TMUX_PANE
  check 'own pane: outside tmux nothing is ours' not _lazyfleet_own_pane %3
  check 'own pane: outside tmux an empty id is not either' not _lazyfleet_own_pane ''
)

# --- _lazyfleet_winframe against a real tmux server
dir="$SANDBOX/a dir with spaces"
mkdir -p $dir
if ! err=$(_lazyfleet_tmux new-session -d -s watched -x 100 -y 20 -c $dir 2>&1); then
  # every check below needs this session: say why once, not as a cascade
  fail "could not start a tmux server: $err (socket in $TMUX_TMPDIR, ${#TMUX_TMPDIR} bytes)"
  finish
fi
_lazyfleet_tmux send-keys -t '=watched:0' 'echo preview-marker' Enter
retry '_lazyfleet_tmux capture-pane -p -t "=watched:0" | gq preview-marker' || fail 'the marker never reached the pane'
pane=$(_lazyfleet_tmux display-message -p -t '=watched:0' '#{pane_id}')

_lazyfleet_winframe '=watched:0'; frame=$REPLY
assert_contains "frame: shows the window's name" 'watched:0' $frame
assert_contains 'frame: shows the pane content' preview-marker $frame
assert_contains 'frame: shows the directory, spaces and all' $dir $frame
check 'frame: the pane id stays out of the header' eval '[[ $frame != *"$pane "* ]]'
check 'frame: a window that is gone has none' not _lazyfleet_winframe '=nope:0'

# somebody else's pane (an unrelated TMUX_PANE) is captured as usual
TMUX_PANE=%9999 _lazyfleet_winframe '=watched:0'
assert_contains 'frame: another pane is still captured' preview-marker $REPLY

# our own pane is not: a note instead of the capture
TMUX_PANE=$pane _lazyfleet_winframe '=watched:0'; rc=$? own=$REPLY
assert_eq 'own frame: status 2, nothing to follow' 2 $rc
check 'own frame: leaves the capture out' eval '[[ $own != *preview-marker* ]]'
assert_contains "own frame: still names the window" 'watched:0' $own
assert_contains 'own frame: explains why' 'lazyfleet is running here' $own

# what made the loop: the capture changed whenever the preview drew, so the
# redraw never stopped. The note must not depend on what the pane shows.
_lazyfleet_tmux send-keys -t '=watched:0' 'echo something-else-entirely' Enter
retry '_lazyfleet_tmux capture-pane -p -t "=watched:0" | gq something-else-entirely' || fail 'the second marker never reached the pane'
TMUX_PANE=$pane _lazyfleet_winframe '=watched:0'
assert_eq 'own frame: the same whatever the pane shows' $own $REPLY

# --- the preview command itself, as fzf runs it (without -f: a single frame)
out=$(TMUX_PANE=$pane _lazyfleet_preview t '=watched:0')
check 'preview: our own window shows the note' eval '[[ $out == *"lazyfleet is running here"* && $out != *preview-marker* ]]'
out=$(_lazyfleet_preview t '=watched:0')
assert_contains 'preview: a window of someone else shows its pane' preview-marker $out

# with -f it keeps drawing until fzf kills it; for our own pane it draws the
# note once and has nothing more to say
watch_out=$SANDBOX/watch.out
TMUX_PANE=$pane zsh -f -c "source $ROOT/lazyfleet.zsh; _lazyfleet_preview -f t '=watched:0'" >$watch_out 2>&1 &
watcher=$!
retry '[[ -s $watch_out ]]' || fail 'preview -f drew nothing'
_lazyfleet_tmux send-keys -t '=watched:0' 'echo late-change' Enter
sleep 1.5   # long enough for several 0.5 s ticks to notice the change
kill $watcher 2>/dev/null; wait $watcher 2>/dev/null
check 'preview -f: no redraw for our own pane' eval '[[ $(<$watch_out) != *$'"'"'\e[2J'"'"'* ]]'
check 'preview -f: it drew the note once' eval '[[ $(<$watch_out) == *"lazyfleet is running here"* ]]'
TMUX_PANE=$pane zsh -f -c "source $ROOT/lazyfleet.zsh; _lazyfleet_preview -f t '=watched:0'" >/dev/null 2>&1 &
watcher=$!
check 'preview -f: for our own pane it ends by itself' retry '! kill -0 $watcher 2>/dev/null'
kill $watcher 2>/dev/null; wait $watcher 2>/dev/null

# --- the whole TUI, started inside one of the sessions it lists (the bug as
# it was seen). "aaa" sorts first, so its row, our own pane, is selected.
autoload -Uz is-at-least
if (( ! $+commands[fzf] )) || ! is-at-least 0.58 ${${(z)$(fzf --version 2>/dev/null)}[1]}; then
  skip 'the TUI inside its own session' 'needs fzf 0.58 or newer'
else
  export LAZYFLEET_UPDATE_CHECK=off LAZYFLEET_PR_STATUS=off LAZYFLEET_AGENT_ICONS=off TERM=${TERM:-xterm-256color}
  [[ $TERM == dumb ]] && export TERM=xterm-256color
  _lazyfleet_tmux new-session -d -s zzz -c $dir
  _lazyfleet_tmux new-session -d -s aaa -x 120 -y 24 -c $dir "$ROOT/bin/lazyfleet windows; sleep 30"
  screen() { _lazyfleet_tmux capture-pane -p -t '=aaa:' }
  check 'tui: starts inside tmux' waitpane aaa ' Windows '
  check 'tui: its own window shows the note' waitpane aaa 'lazyfleet is running here'
  # stable: two looks a second apart (two redraw ticks) see the same screen
  one=$(screen); sleep 1; two=$(screen)
  assert_eq 'tui: the screen settles' $one $two
  check 'tui: no copy of itself inside the preview' eval '(( $(screen | grep -c "Windows") == 1 ))'
  # the next row is "watched", whose pane shows the marker
  _lazyfleet_tmux send-keys -t '=aaa:' j
  check 'tui: another window still shows its pane' retry 'screen | gq -F "late-change"'
  _lazyfleet_tmux send-keys -t '=aaa:' q
  check 'tui: q quits' retry '! screen | gq Windows'
fi

finish
