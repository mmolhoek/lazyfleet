#!/usr/bin/env -S zsh -f
# Tests for the reference of the TUI's keys and marks (lib/keys.zsh): the ?
# screen and lazyfleet keys. Above all, that it matches the TUI: every key it
# binds is explained, every key explained does something, and every mark the
# rows can show is in it.

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools git
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg TMPDIR=$SANDBOX/tmp LANG=C.UTF-8 LC_ALL=C.UTF-8
mkdir -p $HOME $TMPDIR
unset TMUX
export LAZYFLEET_UPDATE_CHECK=off
trap 'rm -rf $SANDBOX' EXIT
source $ROOT/lazyfleet.zsh

T=$'\t'
plain() { REPLY=$(print -rn -- $1 | sed $'s/\x1b\\[[0-9;]*m//g') }

# reply=(the keys of section $1, as the table names them)
keys_of() { local r; _lazyfleet_keys_of $1; local -a k; for r in $reply; do k+=("${${r#*$T}%%$T*}"); done; reply=($k) }
# REPLY=the table's name for fzf key $1
name_of() { case $1 in (enter) REPLY=↵ ;; (tab) REPLY=⇥ ;; (*) REPLY=$1 ;; esac }

# --- the table itself
check 'table: every record has four fields' eval '( for r in $_LAZYFLEET_KEYS; do (( ${#${(ps:\t:)r}} == 4 )) || exit 1; done )'
check 'table: every section is w, t or m' eval '( for r in $_LAZYFLEET_KEYS; do [[ ${r%%$T*} == [wtm] ]] || exit 1; done )'
check 'table: every explanation says more than the short text' eval '( for r in $_LAZYFLEET_KEYS; do f=("${(@ps:\t:)r}"); (( $#f[4] > $#f[3] + 10 )) || exit 1; done )'
for s in w t m; do
  keys_of $s
  assert_eq "table: no key twice in section $s" $#reply ${#${(u)reply}}
done

# --- it matches the keys the TUI binds
_lazyfleet_ui_binds /bin/lf ''
bound=()
# (load is an event of fzf's, not a key)
for a in $reply; do [[ $a == *:transform* && $a != load:* ]] && bound+=(${a%%:*}); done
check 'binds: found the keys' eval '(( $#bound > 15 ))'
keys_of w; wkeys=($reply)
for k in $bound; do
  name_of $k
  [[ $k == esc ]] && REPLY=esc
  check "binds: $k is explained" eval '(( ${wkeys[(Ie)$REPLY]} ))'
done
# every key explained does something in its view (it prints fzf actions)
wkey() { FZF_KEY=$1 FZF_LIST_LABEL=" Worktrees " FZF_INPUT_STATE=hidden _lazyfleet_key w /some/path }
tkey() { FZF_KEY=$1 FZF_LIST_LABEL=" Windows " FZF_INPUT_STATE=hidden _lazyfleet_key t '=a/b:1' }
for k in $wkeys; do
  case $k in (↵) f=enter ;; (⇥) f=tab ;; (*) f=$k ;; esac
  check "worktrees: $k does something" eval '[[ -n $(wkey $f) ]]'
done
keys_of t
for k in $reply; do
  case $k in (↵) f=enter ;; (⇥) f=tab ;; (*) f=$k ;; esac
  check "windows: $k does something" eval '[[ -n $(tkey $f) ]]'
done

# --- the marks: every agent icon and state the rows can show is explained
keys_of m; marks="${(j: :)reply}"
for i in ${(v)_LAZYFLEET_AGENT_ICON}; do check "marks: the agent icon $i" eval '[[ $marks == *$i* ]]'; done
for i in ${(v)_LAZYFLEET_AGENT_STATE_MARK}; do check "marks: the agent state $i" eval '[[ $marks == *$i* ]]'; done
for m in ● '↑3 ↓2' '*' 🐳 '⟳ pulling' '#42 ✓' 'draft' ▲ ⟲; do check "marks: $m" eval '[[ $marks == *"$m"* ]]'; done

# --- wrapping
_lazyfleet_wrap 10 'one two three four'
assert_eq 'wrap: at spaces' 'one two|three four' "${(j:|:)reply}"
_lazyfleet_wrap 5 'a verylongword b'
assert_eq 'wrap: a long word gets a line of its own' 'a|verylongword|b' "${(j:|:)reply}"
_lazyfleet_wrap 10 ''
assert_eq 'wrap: nothing, no lines' 0 $#reply

# --- padding counts screen columns
_lazyfleet_keys_pad ↵;   assert_eq 'pad: a one-column key' "↵${(l:9:)}" $REPLY
_lazyfleet_keys_pad 🐳2; assert_eq 'pad: 🐳 takes two columns' "🐳2${(l:7:)}" $REPLY
_lazyfleet_keys_pad 12345678901; assert_eq 'pad: too long is left as it is' 12345678901 $REPLY

# --- lazyfleet keys
out=$(_lazyfleet_keys); plain $out; txt=$REPLY
for t in 'Worktrees view' 'Windows view' 'Marks on a row'; do assert_contains "keys: has $t" $t $txt; done
assert_contains 'keys: a key with what it does' '  P          push (the whole stack)' $txt
assert_contains 'keys: and the longer explanation under it' 'force-push with lease' $txt
check 'keys: lines fit 80 columns' eval '( for l in ${(f)txt}; do (( ${(m)#l} <= 80 )) || exit 1; done )'
check 'keys: is a command' eval '[[ $(_lazyfleet_main keys | head -1) == *"Worktrees view"* ]]'

# --- the ? screen's lines and preview
rows=("${(@f)$(_lazyfleet_keys_rows w)}")
plain $rows[1]; assert_contains 'rows: the current view first' 'Worktrees view' $REPLY
rows=("${(@f)$(_lazyfleet_keys_rows t)}")
plain $rows[1]; assert_contains 'rows: from the windows, the Windows view first' 'Windows view' $REPLY
check 'rows: one per record, plus three headings' eval '(( $#rows == $#_LAZYFLEET_KEYS + 3 ))'
check 'rows: each starts with a number or a section' eval '( for r in $rows; do [[ ${r%%$T*} == (<1->|-[wtm]) ]] || exit 1; done )'
r=${rows[(r)*push \(the whole stack\)*]}
plain "$(_lazyfleet_keyinfo ${r%%$T*})"
assert_contains 'info: the key and what it does' 'P  push (the whole stack)' $REPLY
assert_contains 'info: and the explanation' 'force-push with lease' $REPLY
plain "$(FZF_PREVIEW_COLUMNS=31 _lazyfleet_keyinfo ${r%%$T*})"
check 'info: wrapped at words to the preview'"'"'s width' eval '( for l in ${(f)REPLY}; do (( ${(m)#l} <= 30 )) || exit 1; done )'
assert_contains 'info: whole words' $'\nPushes the branch to origin\nand sets its upstream.' $REPLY
plain "$(_lazyfleet_keyinfo -m)"; assert_contains 'info: a heading explains its section' 'What the marks after a branch name mean' $REPLY
assert_eq 'info: a number that is no record, nothing' '' "$(_lazyfleet_keyinfo 999)"
assert_eq 'info: no number at all, nothing' '' "$(_lazyfleet_keyinfo '$(touch x)')"

# --- the ? key
check '? in the worktrees: their keys first' eval '[[ $(wkey "?") == "execute("*" _ui_keys w)" ]]'
check '? in the windows: theirs first' eval '[[ $(tkey "?") == "execute("*" _ui_keys t)" ]]'
check '? is typed into the find input while it is shown' eval '[[ ,$_LAZYFLEET_LETTERS, == *,\?,* ]]'
check 'both footers name it' eval '[[ $_LAZYFLEET_FOOTER_WT == *"(?) all keys and marks"* && $_LAZYFLEET_FOOTER_WIN == *"(?) all keys and marks"* ]]'
check 'help names lazyfleet keys' eval '_lazyfleet_help | gq "lazyfleet keys "'

finish
