#!/bin/zsh -f
# End-to-end test in a sandbox HOME with an isolated tmux server.

setopt pipe_fail
ROOT=${0:A:h:h}
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX XDG_CONFIG_HOME=$SANDBOX/.config LAZYSPACE_WORKTREES=$SANDBOX/wt
export LAZYSPACE_TMUX="tmux -L lazyspace-test-$$" SHELL=/bin/zsh
unset TMUX
source $ROOT/lazyspace.zsh

fails=0
ok()   { print -P "%F{green}ok%f   $1" }
fail() { print -P "%F{red}FAIL%f $1"; (( fails++ )) }
check() { local d=$1; shift; if "$@"; then ok $d; else fail $d; fi }
waitfor() { local i; for i in {1..50}; do [[ -e $1 ]] && return 0; sleep 0.1; done; return 1 }
retry() { local i; for i in {1..20}; do eval "$1" && return 0; sleep 0.1; done; return 1 }
waitpane() { local i; for i in {1..50}; do _lazyspace_tmux capture-pane -p -t "=$1:" | grep -q -- $2 && return 0; sleep 0.1; done; return 1 }
cleanup() { _lazyspace_tmux kill-server 2>/dev/null; rm -rf $SANDBOX }
trap cleanup EXIT

# 1. repo with .lazyspace, registered
repo=$SANDBOX/src/app
mkdir -p $repo && cd $repo
git init -q -b main && git config user.email t@t && git config user.name t
print 'secret' > .env
print '.env' > .gitignore
cat > .lazyspace <<'EOF'
# test config
setup=touch .setup-ran
run=echo run-$RANDOM > .run-out; sleep 60
copy=.env
EOF
git add -A && git commit -qm init
_lazyspace_tmux new-session -d -s keepalive
lazyspace add >/dev/null
check 'add registers repo' test "$(lazyspace repos)" = $repo
lazyspace add >/dev/null
check 'add deduplicates' test "$(lazyspace repos | wc -l | tr -d ' ')" = 1

# 2. new
p=$LAZYSPACE_WORKTREES/app/feat-x
lazyspace new feat/x --no-open >/dev/null
check 'new creates worktree' test -d $p
check 'new copies .env' test -f $p/.env
check 'new creates session' _lazyspace_tmux has-session -t '=app/feat-x'
check 'new runs setup' waitfor $p/.setup-ran
check 'new refuses existing' eval '! lazyspace new feat/x --no-open 2>/dev/null'

# 3. ls / status
check 'ls shows row' eval 'lazyspace ls | grep "feat/x" >/dev/null'
check 'ls clean has no *' eval '! lazyspace ls | grep "feat/x" | grep -q "\*"'
print change >> $p/.lazyspace
check 'ls dirty shows *' eval 'lazyspace ls | grep "feat/x" | grep -q "\*"'
check 'resolve by branch' eval '_lazyspace_resolve feat/x && [[ $REPLY == $p ]]'
check 'resolve by session' eval '_lazyspace_resolve app/feat-x && [[ $REPLY == $p ]]'

# 4. run
lazyspace run feat/x
check 'run creates window' waitfor $p/.run-out
first=$(<$p/.run-out)
rm $p/.run-out
lazyspace run feat/x
waitfor $p/.run-out
check 'run respawns (single window)' test "$(_lazyspace_tmux list-windows -t '=app/feat-x' -F '#W' | grep -cx run)" = 1
check 'run re-ran the command' test "$(<$p/.run-out)" != "$first"
cfg=$XDG_CONFIG_HOME/lazyspace/config
print -l '[other]' 'run=touch .wrong-out' '[app]' 'run=touch .cfg-out' >$cfg
lazyspace run feat/x
check 'run prefers personal config section' waitfor $p/.cfg-out
check 'run ignores other sections' test ! -e $p/.wrong-out
print -l "[${repo/#$HOME/~}]" 'run=touch .path-out' >$cfg
lazyspace run feat/x
check 'config section by ~ path' waitfor $p/.path-out
cat >$cfg <<'EOF'
[app]
run=
  echo one > .ml-out

  if true; then
    echo two >> .ml-out
  fi
  sleep 60
other=x
EOF
want=$'echo one > .ml-out\n\nif true; then\n  echo two >> .ml-out\nfi\nsleep 60'
check 'multi-line value keeps relative indent' eval '_lazyspace_conf run $p $repo && [[ $REPLY == $want ]]'
lazyspace run feat/x
waitfor $p/.ml-out; sleep 0.5
check 'multi-line run executes all lines' test "$(<$p/.ml-out)" = $'one\ntwo'
check 'multi-line run window stays alive' eval '_lazyspace_tmux list-panes -t "=app/feat-x:run" -F "#{pane_current_command}" | grep -qx sleep'
check 'config falls through for other keys' eval '_lazyspace_conf copy $p $repo && [[ $REPLY == .env ]]'
rm $cfg

# 5. TUI rows / keys (no terminal needed)
check 'rows include worktree' eval '_lazyspace_rows | grep -q "^w	$p	"'
check 'live marker only on worktree with session' eval '_lazyspace_rows -p | grep "^w	$repo	" | grep -vq "●" && _lazyspace_rows -p | grep "^w	$p	" | grep -q "●"'
check 'worktrees sorted by branch' test "$(_lazyspace_rows -p | cut -f2 | tr '\n' ' ')" = "$p $repo "
_lazyspace_tmux new-session -d -s Zeta; _lazyspace_tmux new-session -d -s alpha
_lazyspace_tmux new-window -d -t '=alpha:10'; _lazyspace_tmux new-window -d -t '=alpha:9'
sessions=$(_lazyspace_winrows | cut -f2 | sed 's/^=//; s/:[0-9]*$//' | uniq)
check 'windows sorted by session' test "$sessions" = "$(print -r -- $sessions | sort -f)"
check 'windows sorted by number' test "$(_lazyspace_winrows | cut -f2 | grep '^=alpha:' | tr '\n' ' ')" = '=alpha:0 =alpha:9 =alpha:10 '
_lazyspace_tmux kill-session -t '=Zeta'; _lazyspace_tmux kill-session -t '=alpha'
check 'reporows include repo' eval '_lazyspace_reporows | grep -q "^r	$repo	"'
check 'key enter opens' eval 'FZF_KEY=enter FZF_LIST_LABEL=" Worktrees " _lazyspace_key w $p | grep -q "^become(printf .* open $p)$"'
check 'key enter on repo filters' eval 'FZF_KEY=enter FZF_LIST_LABEL=" Repos " _lazyspace_key r $repo | grep -q "Worktrees: app"'
check 'key a leaves filtered view' eval 'FZF_KEY=a FZF_LIST_LABEL=" Worktrees: app " _lazyspace_key w $p | grep -q "change-list-label( Worktrees )+reload(.* _rows -s)$"'
check 'winrows list session windows' retry '_lazyspace_winrows | grep -q "^t	=app/feat-x:1	.*1:run"'
_lazyspace_tmux send-keys -t '=app/feat-x:0' 'echo preview-marker' Enter; sleep 0.3
check 'window preview shows pane content' eval '_lazyspace_preview t "=app/feat-x:0" | grep -q preview-marker'
check 'key enter on window switches' eval 'FZF_KEY=enter FZF_LIST_LABEL=" Windows " _lazyspace_key t "=app/feat-x:1" | grep -q "^become(printf .* window \\\\=app/feat-x:1)$"'
check 'key tab cycles repos -> windows' eval 'FZF_KEY=tab FZF_LIST_LABEL=" Repos " _lazyspace_key r $repo | tr "\n" " " | grep -q "Windows .*_winrows"'
check 'key tab cycles windows -> worktrees' eval 'FZF_KEY=tab FZF_LIST_LABEL=" Windows " _lazyspace_key t x | tr "\n" " " | grep -q "Worktrees .*_rows -s"'
check 'key d on window kills it' eval 'FZF_KEY=d FZF_LIST_LABEL=" Windows " _lazyspace_key t "=app/feat-x:1" | grep -q "_ui_killwin"'
check 'key n ignored on window' test -z "$(FZF_KEY=n FZF_LIST_LABEL=' Windows ' _lazyspace_key t x)"
check 'key esc quits when hidden' test "$(FZF_KEY=esc FZF_INPUT_STATE=hidden _lazyspace_key w $p)" = abort

# attach from fzf's become (stdin is /dev/tty) must actually draw the session
_lazyspace_tmux new-session -d -s attach -x 100 -y 10 \
  "echo x | env -u TMUX fzf --bind 'start:become($ROOT/bin/lazyspace open feat/x)'; sleep 5"
sleep 1.5
check 'attach via become renders' eval '_lazyspace_tmux capture-pane -p -t "=attach:" | grep -q "app/feat-"'
_lazyspace_tmux kill-session -t '=attach' 2>/dev/null

# outside tmux, the TUI comes back once the attached session ends
_lazyspace_tmux new-session -d -s tui -x 100 -y 20 "env -u TMUX $ROOT/bin/lazyspace; sleep 5"
check 'tui starts on windows when tmux has some' waitpane tui ' Windows '
_lazyspace_tmux send-keys -t '=tui:' Tab
waitpane tui 'feat/x'; sleep 0.3
# sorted: feat/x first, then main
_lazyspace_tmux send-keys -t '=tui:' j; sleep 0.3
_lazyspace_tmux send-keys -t '=tui:' Enter
sleep 1
check 'tui enter attaches' eval '_lazyspace_tmux list-clients -F "#S" | grep -qx app'
_lazyspace_tmux kill-session -t '=app'
check 'tui returns after session ends' waitpane tui Worktrees
_lazyspace_tmux kill-session -t '=tui' 2>/dev/null

# windows view: filter to the run window, enter attaches to it, detach returns
_lazyspace_tmux new-session -d -s tui -x 120 -y 20 "env -u TMUX $ROOT/bin/lazyspace windows; sleep 5"
waitpane tui '1:run'
_lazyspace_tmux send-keys -t '=tui:' /; sleep 0.3
_lazyspace_tmux send-keys -t '=tui:' -l 'feat-x 1:run'; sleep 0.5
_lazyspace_tmux send-keys -t '=tui:' Enter; sleep 1
check 'windows enter attaches to that window' eval '_lazyspace_tmux list-clients -F "#S #W" | grep -qx "app/feat-x run"'
_lazyspace_tmux detach-client -s '=app/feat-x'
check 'windows view returns after detach' waitpane tui Windows
_lazyspace_tmux kill-session -t '=tui' 2>/dev/null

# pickers
git -C $repo branch -q feat/y
check 'branches lists free branches' eval '_lazyspace_branches $repo | grep -qx feat/y'
check 'branches skips checked-out ones' eval '! _lazyspace_branches $repo | grep -qxE "main|feat/x"'
other=$SANDBOX/src/api
mkdir -p $other && git -C $other init -q
check 'findrepos lists unregistered repos' eval 'LAZYSPACE_SEARCH=$SANDBOX/src _lazyspace_findrepos | grep -qx "~/src/api"'
check 'findrepos skips registered repos' eval '! LAZYSPACE_SEARCH=$SANDBOX/src _lazyspace_findrepos | grep -qx "~/src/app"'
mkdir -p $SANDBOX/elsewhere/api2 && git -C $SANDBOX/elsewhere/api2 init -q
print -l 'search=~/elsewhere' 'search_depth=2' '[app]' 'search=~/src' >$cfg
check 'search setting from config top' eval '_lazyspace_findrepos | grep -qx "~/elsewhere/api2" && ! _lazyspace_findrepos | grep -qx "~/src/api"'
check 'env var beats config setting' eval 'LAZYSPACE_SEARCH=$SANDBOX/src _lazyspace_findrepos | grep -qx "~/src/api"'
check 'section keys are not settings' eval '_lazyspace_setting search_depth X 9 && [[ $REPLY == 2 ]] && _lazyspace_setting nope X d && [[ $REPLY == d ]]'
print 'worktrees=~/wt2' >$cfg
check 'worktrees setting from config' eval 'LAZYSPACE_WORKTREES= lazyspace new feat/cfg --no-open >/dev/null && test -d $SANDBOX/wt2/app/feat-cfg'
lazyspace rm -f -D feat/cfg
rm $cfg
print -l ' search=~/elsewhere' ' [app/]' ' setup=' '  echo a' '    echo b' ' run=go' >$cfg
check 'indented config: setting' eval '_lazyspace_setting search X && [[ $REPLY == "~/elsewhere" ]]'
check 'indented config: multi-line value' eval '_lazyspace_conf setup $p $repo && [[ $REPLY == $'"'"'echo a\n  echo b'"'"' ]]'
check 'indented config: next key ends value' eval '_lazyspace_conf run $p $repo && [[ $REPLY == go ]]'
rm $cfg
pick() {  # pick <query> <key>: run the picker on "alpha beta" in a pane, print REPLY
  rm -f $SANDBOX/pick.out
  _lazyspace_tmux new-session -d -s pick -x 100 -y 15 \
    "zsh -fc 'source $ROOT/lazyspace.zsh; print -l alpha beta | _lazyspace_pick t p && print -r -- \$REPLY >$SANDBOX/pick.out'"
  sleep 0.8
  _lazyspace_tmux send-keys -t '=pick:' -l -- $1
  sleep 0.3
  _lazyspace_tmux send-keys -t '=pick:' $2
  waitfor $SANDBOX/pick.out && cat $SANDBOX/pick.out
  _lazyspace_tmux kill-session -t '=pick' 2>/dev/null
}
check 'pick takes the match' test "$(pick bet Enter)" = beta
check 'pick takes typed name without match' test "$(pick zzz Enter)" = zzz
check 'pick ctrl-n takes typed name' test "$(pick al C-n)" = al

# 6. rm
check 'rm refuses dirty without tty' eval '! lazyspace rm feat/x </dev/null 2>/dev/null'
check 'rm refuses main worktree' eval '! lazyspace rm $repo 2>/dev/null'
lazyspace rm -f -D feat/x
check 'rm removes worktree' test ! -e $p
check 'rm kills session' eval '! _lazyspace_tmux has-session -t "=app/feat-x" 2>/dev/null'
check 'rm deletes branch' eval '! git -C $repo show-ref -q --verify refs/heads/feat/x'

# d on a main worktree offers to forget the repo instead
lazyspace add $other >/dev/null
_lazyspace_tmux new-session -d -s uirm -x 120 -y 10 "zsh -fc 'source $ROOT/lazyspace.zsh; _lazyspace_ui_rm $other; sleep 3'"
waitpane uirm 'Forget api'
_lazyspace_tmux send-keys -t '=uirm:' y
sleep 0.5
check 'd on main worktree forgets repo' eval '! lazyspace repos | grep -qx $other && test -d $other/.git'
_lazyspace_tmux kill-session -t '=uirm' 2>/dev/null

# 7. forget
lazyspace forget app
check 'forget unregisters' test -z "$(lazyspace repos)"

print
(( fails == 0 )) && print -P '%F{green}all passed%f' || { print -P "%F{red}$fails failed%f"; exit 1 }
