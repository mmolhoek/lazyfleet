#!/usr/bin/env -S zsh -f
# Tests for the split between the list and the Details pane (lib/split.zsh):
# < and >, remembered per view and per terminal width, and brought back at the
# start, on a view switch and when the terminal is resized.

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools git
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg XDG_STATE_HOME=$SANDBOX/state TMPDIR=$SANDBOX/tmp
mkdir -p $HOME $TMPDIR
unset TMUX
export LAZYFLEET_UPDATE_CHECK=off
trap 'rm -rf $SANDBOX' EXIT
source $ROOT/lazyfleet.zsh

f=$XDG_STATE_HOME/lazyfleet/split
# key <key> <view label> <width>: the fzf actions of a split key
key() { FZF_KEY=$1 FZF_LIST_LABEL=" $2 " FZF_COLUMNS=$3 _lazyfleet_key w /x }

# --- defaults
_lazyfleet_split_get w 120; assert_eq 'default: the worktrees, half' 50 $REPLY
_lazyfleet_split_get t 120; assert_eq 'default: the windows, mostly preview' 70 $REPLY
_lazyfleet_split_pw w 120;  assert_eq 'default: as fzf takes it' right,50% $REPLY

# --- < and >
assert_eq '<: the Details pane wider' 'change-preview-window(right,55%)' "$(key '<' Worktrees 120)"
assert_eq '<: again' 'change-preview-window(right,60%)' "$(key '<' Worktrees 120)"
check '<: saved' test -s $f
_lazyfleet_split_get w 120; assert_eq '<: remembered for that width' 60 $REPLY
assert_eq '>: narrower' 'change-preview-window(right,55%)' "$(key '>' Worktrees 120)"
_lazyfleet_split_get w 200; assert_eq 'width: another width keeps its own' 50 $REPLY
assert_eq 'width: and changes on its own' 'change-preview-window(right,45%)' "$(key '>' Worktrees 200)"
_lazyfleet_split_get w 120; assert_eq 'width: the first one is untouched' 55 $REPLY
assert_eq 'view: the windows have their own' 'change-preview-window(right,75%)' "$(key '<' Windows 120)"
_lazyfleet_split_get w 120; assert_eq 'view: the worktrees'"'"' is untouched' 55 $REPLY
assert_eq 'file: one line per view and width' 3 "$(wc -l <$f | tr -d ' ')"
check 'file: a loading label is still the worktrees' eval '[[ $(key "<" "Worktrees · checking status…" 120) == *"right,60%"* ]]'

# --- bounds
for i in {1..20}; do key '<' Worktrees 90 >/dev/null; done
_lazyfleet_split_get w 90; assert_eq 'bounds: no wider than 90%' 90 $REPLY
for i in {1..20}; do key '>' Worktrees 90 >/dev/null; done
_lazyfleet_split_get w 90; assert_eq 'bounds: no narrower than 10%' 10 $REPLY

# --- dragged with the mouse: fzf says nothing, but each key notes the split
# (fzf gives the pane floor(width * percent / 100) columns, 4 of them border
# and padding: measured with fzf 0.66 and 0.74)
rm -f $f
nkey() { FZF_KEY=$1 FZF_LIST_LABEL=" $2 " FZF_COLUMNS=$3 FZF_PREVIEW_COLUMNS=$4 _lazyfleet_key w /x }
FZF_COLUMNS=120 FZF_PREVIEW_COLUMNS=40 _lazyfleet_split_now; assert_eq 'now: 40 of 120 columns is 37%' 37 $REPLY
FZF_COLUMNS=87 FZF_PREVIEW_COLUMNS=56 _lazyfleet_split_now; assert_eq 'now: 56 of 87 is 69% (the smallest that gives as many)' 69 $REPLY
FZF_COLUMNS=120 FZF_PREVIEW_COLUMNS=56 _lazyfleet_split_now; assert_eq 'now: the default 50% comes back as 50' 50 $REPLY
check 'now: without a preview, nothing' not eval 'FZF_COLUMNS=120 FZF_PREVIEW_COLUMNS= _lazyfleet_split_now'
nkey q Worktrees 120 40 >/dev/null
_lazyfleet_split_get w 120; assert_eq 'mouse: q notes the split it was dragged to' 37 $REPLY
nkey tab Windows 120 128 >/dev/null
_lazyfleet_split_get t 120; assert_eq 'mouse: any key does, for its own view' 90 $REPLY
print -l 'w 87 70' >$f; m0=$(<$f)
nkey j Worktrees 87 56 >/dev/null
m1=$(<$f)
assert_eq 'mouse: a percent that only rounds differently is not rewritten' $m0 $m1
nkey j Worktrees 120 56 >/dev/null
check 'mouse: the default split is not saved for nothing' eval '[[ $(<$f) != *"w 120"* ]]'
print -l 'w 120 50' >$f
out=$(nkey '<' Worktrees 120 40)
assert_eq 'mouse: < goes on from where it was dragged' 'change-preview-window(right,42%)' $out

# --- a file that is not as lazyfleet writes it
print -l 'w 130 5' 'w 131 notanumber' 'x 132 50' 'w 133 65 extra' 'w 134 65' >$f
_lazyfleet_split_get w 130; assert_eq 'file: out of bounds is the default' 50 $REPLY
_lazyfleet_split_get w 131; assert_eq 'file: no number, the default' 50 $REPLY
_lazyfleet_split_get w 133; assert_eq 'file: a line with more, the default' 50 $REPLY
_lazyfleet_split_get w 134; assert_eq 'file: and a good one is read' 65 $REPLY
check 'set: a bad view is refused' not _lazyfleet_split_set x 120 50
check 'set: a bad width too' not _lazyfleet_split_set w abc 50
rm -f $f
for i in {1..60}; do _lazyfleet_split_set w $(( 100 + i )) 40; done
assert_eq 'file: the 50 latest widths are kept' 50 "$(wc -l <$f | tr -d ' ')"
_lazyfleet_split_get w 160; assert_eq 'file: the latest is among them' 40 $REPLY
_lazyfleet_split_get w 101; assert_eq 'file: the oldest went' 50 $REPLY

# --- brought back: at the start, on a view switch, on a resize
rm -f $f
_lazyfleet_split_set w 150 35; _lazyfleet_split_set t 150 60
FZF_COLUMNS=150 _lazyfleet_ui_start '' ''
assert_contains 'start: the worktrees'"'"' saved split' 'right,35%' "${reply[*]}"
FZF_COLUMNS=150 _lazyfleet_ui_start windows ''
assert_contains 'start: the windows'"'"' saved split' 'right,60%' "${reply[*]}"
out=$(FZF_KEY=tab FZF_LIST_LABEL=" Worktrees " FZF_COLUMNS=150 _lazyfleet_key w /x)
assert_contains 'switch: to the windows brings theirs' 'change-preview-window(right,60%)' $out
out=$(FZF_KEY=tab FZF_LIST_LABEL=" Windows " FZF_COLUMNS=150 _lazyfleet_key t '=a/b:1')
assert_contains 'switch: back brings the worktrees'"'"'' 'change-preview-window(right,35%)' $out
assert_eq 'resize: the split saved for the new width' 'change-preview-window(right,35%)' "$(FZF_LIST_LABEL=' Worktrees ' FZF_COLUMNS=150 _lazyfleet_split_resized)"
assert_eq 'resize: a width with none, the default' 'change-preview-window(right,50%)' "$(FZF_LIST_LABEL=' Worktrees ' FZF_COLUMNS=99 _lazyfleet_split_resized)"
_lazyfleet_ui_binds /bin/lf ''
check 'resize: bound' eval '(( ${reply[(I)resize:transform:*_split_resized]} ))'
check 'keys: < and > are bound' eval '(( ${reply[(I)<:transform:*]} && ${reply[(I)>:transform:*]} ))'
check 'keys: typed into the find input while it is shown' eval '[[ ,$_LAZYFLEET_LETTERS, == *,\<,* && ,$_LAZYFLEET_LETTERS, == *,\>,* ]]'
check 'footers: both name them' eval '[[ $_LAZYFLEET_FOOTER_WT == *"< > split"* && $_LAZYFLEET_FOOTER_WIN == *"< > split"* ]]'

finish
