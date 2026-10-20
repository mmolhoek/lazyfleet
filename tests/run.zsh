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
check 'ls shows row' eval 'lazyspace ls | grep -q "feat/x"'
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

# 5. TUI rows / keys (no terminal needed)
check 'rows include worktree' eval '_lazyspace_rows | grep -q "^w	$p	"'
check 'live marker only on worktree with session' eval '_lazyspace_rows -p | grep "^w	$repo	" | grep -vq "●" && _lazyspace_rows -p | grep "^w	$p	" | grep -q "●"'
check 'reporows include repo' eval '_lazyspace_reporows | grep -q "^r	$repo	"'
check 'key enter opens' eval 'FZF_KEY=enter FZF_LIST_LABEL=" Worktrees " _lazyspace_key w $p | grep -q "^become(.* open "'
check 'key enter on repo filters' eval 'FZF_KEY=enter FZF_LIST_LABEL=" Repos " _lazyspace_key r $repo | grep -q "Worktrees: app"'
check 'key esc quits when hidden' test "$(FZF_KEY=esc FZF_INPUT_STATE=hidden _lazyspace_key w $p)" = abort

# attach from fzf's become (stdin is /dev/tty) must actually draw the session
_lazyspace_tmux new-session -d -s attach -x 100 -y 10 \
  "echo x | env -u TMUX fzf --bind 'start:become($ROOT/bin/lazyspace open feat/x)'; sleep 5"
sleep 1.5
check 'attach via become renders' eval '_lazyspace_tmux capture-pane -p -t "=attach:" | grep -q "app/feat-"'
_lazyspace_tmux kill-session -t '=attach' 2>/dev/null

# 6. rm
check 'rm refuses dirty without tty' eval '! lazyspace rm feat/x </dev/null 2>/dev/null'
check 'rm refuses main worktree' eval '! lazyspace rm $repo 2>/dev/null'
lazyspace rm -f -D feat/x
check 'rm removes worktree' test ! -e $p
check 'rm kills session' eval '! _lazyspace_tmux has-session -t "=app/feat-x" 2>/dev/null'
check 'rm deletes branch' eval '! git -C $repo show-ref -q --verify refs/heads/feat/x'

# 7. forget
lazyspace forget app
check 'forget unregisters' test -z "$(lazyspace repos)"

print
(( fails == 0 )) && print -P '%F{green}all passed%f' || { print -P "%F{red}$fails failed%f"; exit 1 }
