#!/usr/bin/env -S zsh -f
# Tests for the message history (lib/history.zsh): while the TUI runs, what
# lazyfleet says goes to ~/.lazyfleet_history instead of the terminal behind
# it, the latest 1000 lines are kept, and the TUI's footer shows the last one
# of its own run.

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools git tmux
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg XDG_STATE_HOME=$SANDBOX/state TMPDIR=$SANDBOX/tmp
mkdir -p $HOME $TMPDIR
unset TMUX LAZYFLEET_TUI LAZYFLEET_HISTORY
export LAZYFLEET_UPDATE_CHECK=off
trap 'tmux_cleanup; rm -rf $SANDBOX' EXIT
source $ROOT/lazyfleet.zsh

h=$HOME/.lazyfleet_history
STAMP='[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}'
fresh() { rm -f $h; _lazyfleet_errs=() }
lines() { [[ -e $h ]] && wc -l <$h | tr -d ' ' || print 0 }

# --- the file
_lazyfleet_history_file; assert_eq 'file: ~/.lazyfleet_history' $h $REPLY
LAZYFLEET_HISTORY=$SANDBOX/other _lazyfleet_history_file
assert_eq 'file: LAZYFLEET_HISTORY names another' $SANDBOX/other $REPLY

fresh; _lazyfleet_history_add 'no pull request known for feat/x'
check 'add: a line with the date and time' gq -xE "$STAMP no pull request known for feat/x" $h
_lazyfleet_history_add 'second'
check 'add: appends' eval '[[ $(lines) == 2 && $(tail -1 $h) == *" second" ]]'

fresh; _lazyfleet_history_add $'\e[33mWarning:\e[0m two\nlines\tand a tab'
check 'add: one line, without colours or control characters' gq -xE "$STAMP Warning: two lines and a tab" $h
fresh; _lazyfleet_history_add $'  \n\t '
check 'add: nothing but blanks is not added' test ! -e $h
fresh; _lazyfleet_history_add '[detached (from session app/feat-x)]'
check 'add: brackets are kept as they are' gq -xE "$STAMP \[detached \(from session app/feat-x\)\]" $h

fresh; for i in {1..1005}; do print -r -- "2026-01-01 00:00:00 old $i"; done >$h
_lazyfleet_history_add newest
assert_eq 'add: keeps the latest 1000 lines' 1000 $(lines)
check 'add: drops the oldest' eval '[[ $(head -1 $h) == "2026-01-01 00:00:00 old 7" && $(tail -1 $h) == *" newest" ]]'
check 'add: leaves no temp file behind' eval '[[ -z $(print -l $h.*(N)) ]]'

# --- the last message of this run
fresh; _lazyfleet_history_add hello
check 'last: nothing outside the TUI' not _lazyfleet_history_last
LAZYFLEET_TUI='2000-01-01 00:00:00'
check 'last: in the TUI, the last line' eval '_lazyfleet_history_last && [[ $REPLY == <->:<->" hello" ]]'
check 'last: shows hours and minutes only' eval '_lazyfleet_history_last && (( ${#REPLY%% *} == 5 ))'
LAZYFLEET_TUI='2999-01-01 00:00:00'
check 'last: not one from before this run' not _lazyfleet_history_last
LAZYFLEET_TUI='2000-01-01 00:00:00'
fresh; check 'last: none without a file' not _lazyfleet_history_last
print -r -- 'not a history line' >$h
check 'last: not a line it did not write' not _lazyfleet_history_last
unset LAZYFLEET_TUI

# --- errors
fresh; out=$(_lazyfleet_err 'it broke' 2>&1)
assert_eq 'err: outside the TUI, on stderr' 'lazyfleet: it broke' $out
check 'err: outside the TUI, not in the history' test ! -e $h
fresh; out=$(LAZYFLEET_TUI=x _lazyfleet_err 'it broke' 2>&1); rc=$?
assert_eq 'err: in the TUI, nothing on the terminal' '' "$out"
assert_eq 'err: in the TUI, still fails' 1 $rc
check 'err: in the TUI, in the history' gq -E "$STAMP it broke$" $h
fresh; LAZYFLEET_TUI=x _lazyfleet_err one; LAZYFLEET_TUI=x _lazyfleet_err two
assert_eq 'err: in the TUI, kept back for a pause' 'lazyfleet: one|lazyfleet: two' "${(j:|:)_lazyfleet_errs}"
# (no terminal here: the read fails, and that is fine)
out=$(_lazyfleet_pause 2>&1 </dev/null)
assert_contains 'pause: prints the errors kept back' $'lazyfleet: one\nlazyfleet: two\npress any key' $out
_lazyfleet_pause >/dev/null 2>&1 </dev/null
assert_eq 'pause: then forgets them' 0 $#_lazyfleet_errs
out=$(_lazyfleet_pause 2>&1 </dev/null)
check 'pause: without errors, only the prompt' eval '[[ $out == "press any key"* && $out != *lazyfleet:* ]]'

# --- tmux is never handed LAZYFLEET_TUI: its sessions' shells would have it
use_tmux history
LAZYFLEET_TUI='2000-01-01 00:00:00' _lazyfleet_tmux new-session -d -s h
check 'tmux: a server started from the TUI does not think it is the TUI' \
  eval '[[ $(_lazyfleet_tmux show-environment -g LAZYFLEET_TUI 2>/dev/null) != LAZYFLEET_TUI=?* ]]'
check 'tmux: the TUI itself still is' eval 'LAZYFLEET_TUI=x; [[ -n $LAZYFLEET_TUI ]]'
unset LAZYFLEET_TUI
tmux_cleanup

# --- tmux's "[detached (from session x)]" when attached from the TUI
fake_attach() { print -r -- '[detached (from session app/feat-x)]'; print -ru2 -- 'tmux complains'; return ${ATTACH_RC:-0} }
fresh; out=$( (_lazyfleet_attach_tty() { fake_attach }; LAZYFLEET_TUI=x _lazyfleet_attach '=app/feat-x') 2>&1 )
assert_eq 'attach: in the TUI, nothing left on the terminal' '' "$out"
check 'attach: what tmux said is in the history' gq -E "$STAMP \[detached \(from session app/feat-x\)\]$" $h
check 'attach: its errors too' gq -E "$STAMP tmux complains$" $h
check 'attach: leaves no file behind' eval '[[ -z $(print -l $TMPDIR/lazyfleet-$UID/attach.*(N)) ]]'
fresh; ( _lazyfleet_attach_tty() { fake_attach }; ATTACH_RC=1 LAZYFLEET_TUI=x _lazyfleet_attach x ) 2>/dev/null
assert_eq 'attach: its status is kept' 1 $?
fresh; out=$( (_lazyfleet_attach_tty() { fake_attach }; _lazyfleet_attach x) 2>&1 )
assert_contains 'attach: outside the TUI, tmux speaks on the terminal as always' '[detached (from session app/feat-x)]' $out
check 'attach: outside the TUI, no history' test ! -e $h

# --- the footer. The footers are globals: each case in a subshell
(
  wt0=$_LAZYFLEET_FOOTER_WT win0=$_LAZYFLEET_FOOTER_WIN
  fresh; export LAZYFLEET_TUI='2000-01-01 00:00:00'
  _lazyfleet_footers
  assert_eq 'footer: nothing said, as it was' "$wt0" "$_LAZYFLEET_FOOTER_WT"
  _lazyfleet_err 'no pull request known for feat/x'; _lazyfleet_footers
  check 'footer: the last message, as its last line' eval '[[ $_LAZYFLEET_FOOTER_WT == "$wt0"$'"'"'\n› '"'"'<->:<->" no pull request known for feat/x" ]]'
  check 'footer: the windows'"'"' too' eval '[[ $_LAZYFLEET_FOOTER_WIN == "$win0"$'"'"'\n› '"'"'*"feat/x" ]]'
  _lazyfleet_err 'something else'; _lazyfleet_footers; _lazyfleet_footers
  check 'footer: a newer one takes its place, once' eval '[[ $_LAZYFLEET_FOOTER_WT == "$wt0"$'"'"'\n› '"'"'<->:<->" something else" ]]'
  out=$(FZF_LIST_LABEL=' Worktrees · loading… ' _lazyfleet_ui_refresh)
  assert_contains 'refresh: the footer of the view, with the message' "$wt0"$'\n› ' $out
  check 'refresh: and the title' eval '[[ $out == "change-border-label( lazyfleet )+change-footer("* ]]'
  out=$(FZF_LIST_LABEL=' Windows ' _lazyfleet_ui_refresh)
  assert_contains 'refresh: in the windows, their footer' "$win0"$'\n› ' $out
)
(
  wt0=$_LAZYFLEET_FOOTER_WT
  fresh; unset LAZYFLEET_TUI; _lazyfleet_history_add 'from another run'
  _lazyfleet_footers
  assert_eq 'footer: not outside a TUI run' "$wt0" "$_LAZYFLEET_FOOTER_WT"
)
(
  wt0=$_LAZYFLEET_FOOTER_WT
  fresh; export LAZYFLEET_TUI='2000-01-01 00:00:00'
  _lazyfleet_version_line() { REPLY='lazyfleet v0.1.0' }
  _lazyfleet_err oops; _lazyfleet_footers
  check 'footer: the message above the version line' eval '[[ $_LAZYFLEET_FOOTER_WT == "$wt0"$'"'"'\n› '"'"'<->:<->" oops"$'"'"'\nlazyfleet v0.1.0'"'"' ]]'
)

# --- keys whose command may say something bring the footer up to date after
k() { FZF_COLUMNS=120 FZF_KEY=$1 FZF_LIST_LABEL=" ${3:-Worktrees} " _lazyfleet_key ${2:-w} /some/path }
for key in o O D d S r P c C a; do
  check "keys: $key refreshes the footer after its command" eval '[[ $(k $key) == *"+transform("*" _ui_refresh)" ]]'
done
check 'keys: d on a window does too' eval '[[ $(k d t Windows) == *"+transform("*" _ui_refresh)" ]]'
check 'keys: enter does not need to (the TUI starts fzf again)' eval '[[ $(k enter) != *_ui_refresh* ]]'

# --- a failed background pull is noted too
(
  fresh; export LAZYFLEET_TUI=x
  _lazyfleet_pulldir; print -r -- 'fatal: not possible to fast-forward' >$REPLY/${${:-/wt/app}//\//%}.err
  _lazyfleet_ui_pullfail >/dev/null 2>&1 </dev/null
  check 'pull: a failed one is in the history' gq -E "$STAMP pull failed in /wt/app$" $h
)

# --- the TUI sets LAZYFLEET_TUI for what it runs, and only while it runs
(
  fzf() { print -r -- "${LAZYFLEET_TUI:-unset}" >$SANDBOX/seen; return 130 }
  _lazyfleet_tmux() { return 1 }
  _lazyfleet_ui 2>/dev/null
  check 'tui: what it runs sees when it started' gq -xE "$STAMP" $SANDBOX/seen
  check 'tui: not after' test -z "$LAZYFLEET_TUI"
)

finish
