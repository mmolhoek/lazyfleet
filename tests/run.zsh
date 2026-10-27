#!/usr/bin/env -S zsh -f
# End-to-end test in a sandbox HOME with an isolated tmux server.

setopt pipe_fail
zmodload zsh/stat
ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools git tmux fzf
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX XDG_CONFIG_HOME=$SANDBOX/.config LAZYFLEET_WORKTREES=$SANDBOX/wt TMPDIR=$SANDBOX/tmp
mkdir -p $TMPDIR
# setup runs through an interactive zsh: give it an rc file (or zsh's new-user
# wizard blocks), which asks a question first when ~/.ask exists, like a mise
# enter hook
print -r -- '[[ -e ~/.ask ]] && { rm ~/.ask; read -r ans; print -r -- $ans >~/answer }' >$SANDBOX/.zshrc
# keep the test tmux server's socket in the sandbox, so it goes away with it
# every fixture repo commits, also on hosts without a git identity
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export TMUX_TMPDIR=$SANDBOX
export LAZYFLEET_TMUX="tmux -L lazyfleet-test-$$" SHELL=${commands[zsh]}
unset TMUX
source $ROOT/lazyfleet.zsh

cleanup() { _lazyfleet_tmux kill-server 2>/dev/null; rm -rf $SANDBOX }
trap cleanup EXIT

# 1. repo with .lazyfleet, registered
repo=$SANDBOX/src/app
mkdir -p $repo && cd $repo
git init -q -b main
print 'secret' > .env
print '.env' > .gitignore
cat > .lazyfleet <<'EOF'
# test config
setup=touch .setup-ran
copy=.env
EOF
git add -A && git commit -qm init
check 'no rows without repos or windows' eval '[[ -z $(_lazyfleet_rows) && -z $(LAZYFLEET_TMUX="tmux -L lazyfleet-none-$$" _lazyfleet_winrows) ]]'
_lazyfleet_tmux new-session -d -s keepalive
lazyfleet add >/dev/null
_lazyfleet_help() { print stale }
check 'the command runs the code on disk, not a stale copy in the shell' eval '[[ $(lazyfleet help) != stale ]]'
source $ROOT/lazyfleet.zsh
check 'add registers repo' test "$(lazyfleet repos)" = $repo
lazyfleet add >/dev/null
check 'add deduplicates' test "$(lazyfleet repos | wc -l | tr -d ' ')" = 1

# 2. new
p=$LAZYFLEET_WORKTREES/app/feat-x
lazyfleet new feat/x --no-open >/dev/null 2>$SANDBOX/new.err
check 'new creates worktree' test -d $p
out=$(lazyfleet new -q feat/quiet --no-open 2>&1 >/dev/null); rc=$?
lazyfleet rm -f -D feat/quiet 2>/dev/null
check 'new -q keeps the summary out of the terminal' eval '(( rc == 0 )) && [[ -z $out ]]'
check 'new reports the branch' gq -F 'branch  feat/x (new, from HEAD)' $SANDBOX/new.err
check 'new reports what it copied' gq -F 'copy    .env  from ~/src/app (.lazyfleet)' $SANDBOX/new.err
check 'new reports the setup' gq -F 'setup   touch .setup-ran  (.lazyfleet) → running in session app/feat-x' $SANDBOX/new.err
check 'new copies .env' test -f $p/.env
check 'new creates session' _lazyfleet_tmux has-session -t '=app/feat-x'
# #() in the status bar only runs for an attached client
_lazyfleet_tmux new-session -d -s sb -x 150 -y 5 "env -u TMUX $LAZYFLEET_TMUX attach -t \"=app/feat-x\""
check 'the status bar shows the branch' retry '_lazyfleet_tmux capture-pane -p -t "=sb:" | tail -1 | gq -F feat/x'
_lazyfleet_tmux kill-session -t '=sb'
LAZYFLEET_STATUS_BRANCH=off lazyfleet new feat/nosb --no-open >/dev/null 2>&1
check 'status_branch=off leaves the status bar alone' eval '_lazyfleet_tmux has-session -t "=app/feat-nosb" && [[ -z $(_lazyfleet_tmux show -v -t "=app/feat-nosb:" status-right) ]]'
lazyfleet rm -f -D feat/nosb 2>/dev/null
check 'new runs setup' waitfor $p/.setup-ran
cfg=$XDG_CONFIG_HOME/lazyfleet/config
mkdir -p ${cfg:h}
print -l '[app]' 'copy=.env .nope' 'setup=' '  touch .ml-a' '  touch .ml-b' >$cfg
lazyfleet new feat/sum --no-open >/dev/null 2>$SANDBOX/new.err
check 'new names the config section' gq -F '(~/.config/lazyfleet/config [app])' $SANDBOX/new.err
check 'new reports skipped copies' gq -F 'skipped .nope: not in the main worktree' $SANDBOX/new.err
check 'new shows a multi-line setup' eval 'gq -F "setup   2-line script" $SANDBOX/new.err && gq -F "touch .ml-b" $SANDBOX/new.err'
check 'setup window starts with the summary' eval 'head -1 $TMPDIR/lazyfleet-$UID/app-feat-sum.setup.* | gq "lazyfleet: new worktree"'
check 'setup runs as the window command, not typed in' eval '_lazyfleet_tmux display -p -t "=app/feat-sum:0" "#{pane_start_command}" | gq -- "-ic .*[.] "'
check 'multi-line setup still runs' waitfor $LAZYFLEET_WORKTREES/app/feat-sum/.ml-b
rm $cfg
lazyfleet rm -f -D feat/sum 2>/dev/null
# an empty setup= is no setup (it once ran the summary's first line as a command)
print -l '[app]' 'setup=' >$cfg
lazyfleet new feat/emptysetup --no-open >/dev/null 2>$SANDBOX/new.err
check 'an empty setup= is reported as no setup' gq -F 'nothing (no setup= configured)' $SANDBOX/new.err
check 'an empty setup= starts no setup window command' eval '! _lazyfleet_tmux display -p -t "=app/feat-emptysetup:0" "#{pane_start_command}" | gq -- "-ic"'
rm $cfg
lazyfleet rm -f -D feat/emptysetup 2>/dev/null
# a file that can't be copied fails new before setup starts
print -l '[app]' 'copy=.env .locked' 'setup=touch .setup-ran' >$cfg
print x >$repo/.locked; chmod 000 $repo/.locked
# root reads a mode 000 file
noperm=; (( EUID == 0 )) && noperm='running as root'
check_unless "$noperm" 'new fails when a copy fails' eval '! lazyfleet new feat/cpfail --no-open >/dev/null 2>$SANDBOX/new.err && gq -F "could not copy .locked" $SANDBOX/new.err'
check_unless "$noperm" 'a failed copy starts no setup' eval '! _lazyfleet_tmux has-session -t "=app/feat-cpfail" 2>/dev/null && sleep 0.5 && test ! -e $LAZYFLEET_WORKTREES/app/feat-cpfail/.setup-ran'
rm -f $cfg $repo/.locked
lazyfleet rm -f -D feat/cpfail 2>/dev/null
# a question while the shell starts gets the user's answer, not our setup keys
touch $HOME/.ask
lazyfleet new feat/ask --no-open >/dev/null 2>/dev/null
# the rc removes ~/.ask right before it reads the answer, so wait for that
# (a fixed pause was too short on a loaded machine)
waitfor_gone $HOME/.ask
_lazyfleet_tmux send-keys -t '=app/feat-ask:' staging Enter
check 'startup question gets the user'"'"'s answer' eval 'waitfor $HOME/answer && [[ $(<$HOME/answer) == staging ]]'
check 'setup runs after the question' waitfor $LAZYFLEET_WORKTREES/app/feat-ask/.setup-ran
check 'setup window says it finished' waitpane app/feat-ask 'setup finished (exit 0)'
lazyfleet rm -f -D feat/ask 2>/dev/null
rm -f $HOME/answer
check 'new refuses existing' eval '! lazyfleet new feat/x --no-open 2>/dev/null'

# 3. ls / status
check 'ls shows row' eval 'lazyfleet ls | grep "feat/x" >/dev/null'
# the setup's own .setup-ran is untracked, so it counts as a change
check 'ls untracked shows *' eval 'lazyfleet ls | grep "feat/x" | gq "\*"'
mv $p/.setup-ran $SANDBOX/setup-ran.keep
check 'ls clean has no *' eval '! lazyfleet ls | grep "feat/x" | gq "\*"'
mv $SANDBOX/setup-ran.keep $p/.setup-ran
print change >> $p/.lazyfleet
check 'ls dirty shows *' eval 'lazyfleet ls | grep "feat/x" | gq "\*"'
# status and preview don't take index.lock (a commit or pull in that
# worktree would fail on it): a touched clean file leaves the index stale
idx=$(git -C $p rev-parse --path-format=absolute --git-path index)
sleep 1.1; touch $p/.gitignore; m0=$(zstat +mtime $idx 2>/dev/null || stat -f %m $idx)
_lazyfleet_wtstatus $p >/dev/null; _lazyfleet_preview w $p >/dev/null 2>&1
check 'status leaves the index alone' eval '[[ $(zstat +mtime $idx 2>/dev/null || stat -f %m $idx) == $m0 ]]'
check 'resolve by branch' eval '_lazyfleet_resolve feat/x && [[ $REPLY == $p ]]'
check 'resolve by session' eval '_lazyfleet_resolve app/feat-x && [[ $REPLY == $p ]]'

# 4. config lookup
cfg=$XDG_CONFIG_HOME/lazyfleet/config
pcfg=$XDG_CONFIG_HOME/lazyfleet/projects/app.conf
rm -f $cfg $pcfg
check 'settings start from a commented example' eval 'EDITOR=true lazyfleet config </dev/null && gq "^# search=" $cfg && ! gq "^[^#]" $cfg'
check 'config runs the editor with its args' test "$(EDITOR='print -r --' VISUAL= lazyfleet config)" = $cfg
check 'VISUAL wins over EDITOR' test "$(EDITOR=false VISUAL='print -r --' lazyfleet config)" = $cfg
check 'config <repo> opens the project file' test "$(EDITOR='print -r --' VISUAL= lazyfleet config app)" = $pcfg
check 'project file starts with the repo'"'"'s .lazyfleet for reference' eval 'gq "^# lazyfleet config for app " $pcfg && gq "^#   setup=touch .setup-ran" $pcfg && ! gq "^[^#]" $pcfg'
print -l '[app]' 'setup=from-section' >$cfg
print 'setup=from-project' >$pcfg
check 'project file wins over a [section]' eval '_lazyfleet_conf setup $p $repo && [[ $REPLY == from-project && $_lazyfleet_from == "~/.config/lazyfleet/projects/app.conf" ]]'
rm -f $cfg $pcfg
cfg=$XDG_CONFIG_HOME/lazyfleet/config
print -l '[other]' 'setup=wrong' '[app]' 'setup=from-config' >$cfg
check 'personal config section wins, others ignored' eval '_lazyfleet_conf setup $p $repo && [[ $REPLY == from-config ]]'
print -l "[${repo/#$HOME/~}]" 'setup=by-path' >$cfg
check 'config section by ~ path' eval '_lazyfleet_conf setup $p $repo && [[ $REPLY == by-path ]]'
cat >$cfg <<'EOF'
[app]
setup=
  echo one > .ml-out

  if true; then
    echo two >> .ml-out
  fi
  sleep 60
other=x
EOF
want=$'echo one > .ml-out\n\nif true; then\n  echo two >> .ml-out\nfi\nsleep 60'
check 'multi-line value keeps relative indent' eval '_lazyfleet_conf setup $p $repo && [[ $REPLY == $want ]]'
check 'config falls through for other keys' eval '_lazyfleet_conf copy $p $repo && [[ $REPLY == .env ]]'
rm $cfg

# 5. TUI rows / keys (no terminal needed)
_lazyfleet_tmux new-window -d -n extra -t '=app/feat-x:'
check 'rows include worktree' eval '_lazyfleet_rows | gq "^w	$p	"'
check 'live marker only on worktree with session' eval '_lazyfleet_rows -p | grep "^w	$repo	" | gq -v "●" && _lazyfleet_rows -p | grep "^w	$p	" | gq "●"'
check 'worktrees sorted by branch' test "$(_lazyfleet_rows -p | cut -f2 | tr '\n' ' ')" = "$p $repo "
_lazyfleet_tmux new-session -d -s Zeta; _lazyfleet_tmux new-session -d -s alpha
_lazyfleet_tmux new-window -d -t '=alpha:10'; _lazyfleet_tmux new-window -d -t '=alpha:9'
sessions=$(_lazyfleet_winrows | cut -f2 | sed 's/^=//; s/:[0-9]*$//' | uniq)
check 'windows sorted by session' test "$sessions" = "$(print -r -- $sessions | sort -f)"
check 'windows sorted by number' test "$(_lazyfleet_winrows | cut -f2 | grep '^=alpha:' | tr '\n' ' ')" = '=alpha:0 =alpha:9 =alpha:10 '
_lazyfleet_tmux kill-session -t '=Zeta'; _lazyfleet_tmux kill-session -t '=alpha'
check 'key enter opens' eval 'FZF_KEY=enter FZF_LIST_LABEL=" Worktrees " _lazyfleet_key w $p | gq "^become(printf .* open {2})$"'
check 'key a adds a project and shows the worktrees' eval 'FZF_KEY=a FZF_LIST_LABEL=" Windows " _lazyfleet_key t x | tr "\n" " " | gq "change-list-label( Worktrees · loading… ).*reload(.* _rows) $"'
check 'winrows list session windows' retry '_lazyfleet_winrows | gq "^t	=app/feat-x:1	.*1:extra"'
# tmux >= 3.4 turns tabs in -F output into "_" off a terminal: targets must come out intact
check 'winrows targets are intact' eval '_lazyfleet_winrows | cut -f2 | gq -x "=app/feat-x:0"'
_lazyfleet_tmux send-keys -t '=app/feat-x:0' 'echo preview-marker' Enter; sleep 0.3
check 'window preview shows pane content' eval '_lazyfleet_preview t "=app/feat-x:0" | gq preview-marker'
check 'key enter on window switches' eval 'FZF_KEY=enter FZF_LIST_LABEL=" Windows " _lazyfleet_key t "=app/feat-x:1" | gq "^become(printf .* window {2})$"'
check 'key tab cycles worktrees -> windows' eval 'FZF_KEY=tab FZF_LIST_LABEL=" Worktrees " _lazyfleet_key w $p | tr "\n" " " | gq "Windows .*_winrows"'
check 'there is no repos view any more' eval '! (( $+functions[_lazyfleet_reporows] )) && [[ $_LAZYFLEET_FOOTER_WT$_LAZYFLEET_FOOTER_WIN != *repos* ]]'
check 'tab never leads to a repos list' eval 'for l in " Worktrees " " Windows "; do FZF_KEY=tab FZF_LIST_LABEL=$l _lazyfleet_key w $p; done | { ! gq "Repos" }'
check 'enter on a worktree opens it, never a repo filter' eval 'FZF_KEY=enter FZF_LIST_LABEL=" Worktrees " _lazyfleet_key r $repo | { ! gq "_rows -L" }'
check 'key tab cycles windows -> worktrees' eval 'FZF_KEY=tab FZF_LIST_LABEL=" Windows " _lazyfleet_key t x | tr "\n" " " | gq "Worktrees · loading… .*_rows)"'
check 'windows view widens the preview' eval 'FZF_KEY=w FZF_LIST_LABEL=" Worktrees " _lazyfleet_key w x | tr "\n" " " | gq "change-preview-window(right,70%)"'
check 'leaving windows view restores the split' eval 'FZF_KEY=tab FZF_LIST_LABEL=" Windows " _lazyfleet_key t x | tr "\n" " " | gq "change-preview-window(right,50%)"'
check 'key d on window kills it' eval 'FZF_KEY=d FZF_LIST_LABEL=" Windows " _lazyfleet_key t "=app/feat-x:1" | gq "_ui_killwin"'
check 'key n ignored on window' test -z "$(FZF_KEY=n FZF_LIST_LABEL=' Windows ' _lazyfleet_key t x)"
check 'load: plain rows, then status rows' eval 'FZF_LIST_LABEL=" Worktrees · loading… " _lazyfleet_loaded | gq "^transform-list-label(.* _wtlabel checking)+reload-sync(.* _rows -s)$"'
check 'load: checking label' test "$(FZF_LIST_LABEL=' Worktrees · loading… ' _lazyfleet_wtlabel checking)" = ' Worktrees · checking status… '
check 'load: status done clears the marker' eval '[[ $(FZF_LIST_LABEL=" Worktrees · checking status… " _lazyfleet_loaded) == *"_wtlabel done)" && $(FZF_LIST_LABEL=" Worktrees · checking status… " _lazyfleet_wtlabel done) == " Worktrees " ]]'
pf=$SANDBOX/posfile
print 3 >$pf
check 'load: moves to the handed-over row once' eval '[[ $(LAZYFLEET_POSFILE=$pf FZF_LIST_LABEL=" Windows " _lazyfleet_loaded) == "pos(3)" && ! -e $pf ]]'
print 2 >$pf
check 'load: handed-over row before status reload' eval 'LAZYFLEET_POSFILE=$pf FZF_LIST_LABEL=" Worktrees · loading… " _lazyfleet_loaded | gq "^pos(2)+transform-list-label(.* _wtlabel checking)+reload-sync("'
check 'load: other views do nothing' test -z "$(FZF_LIST_LABEL=' Windows ' _lazyfleet_loaded)"
check 'keys see through the loading marker' eval 'FZF_KEY=R FZF_LIST_LABEL=" Worktrees · checking status… " _lazyfleet_key w $p | gq "change-list-label( Worktrees · loading… )+reload(.* _rows)"'
check 'c on a worktree opens its project config' eval 'FZF_KEY=c FZF_LIST_LABEL=" Worktrees " _lazyfleet_key w $p | gq "^execute(.* config {2})+.*reload("'
check 'c in the windows view opens the settings' eval 'FZF_KEY=c FZF_LIST_LABEL=" Windows " _lazyfleet_key t x | gq "^execute(.* config)+reload(.*_winrows)$"'
check 'C opens the settings' eval 'FZF_KEY=C FZF_LIST_LABEL=" Windows " _lazyfleet_key t x | gq "^execute(.* config)+reload(.*_winrows)$"'
check 'r reloads' eval 'FZF_KEY=r FZF_LIST_LABEL=" Windows " _lazyfleet_key t x | gq "^reload(.*_winrows)"'
check 'key esc quits when hidden' test "$(FZF_KEY=esc FZF_INPUT_STATE=hidden _lazyfleet_key w $p)" = abort

# some fzf builds crash on become (seen: fzf 0.71 on Termux under proot)
_lazyfleet_tmux new-session -d -s probe "env -u TMUX fzf --bind 'start:become(touch $SANDBOX/become-ok)' </dev/null; sleep 1"
nobecome=; waitfor $SANDBOX/become-ok || nobecome='this fzf crashes on become'
_lazyfleet_tmux kill-session -t '=probe' 2>/dev/null

# attach from fzf's become (stdin is /dev/tty) must actually draw the session
_lazyfleet_tmux new-session -d -s attach -x 100 -y 10 \
  "echo x | env -u TMUX fzf --bind 'start:become($ROOT/bin/lazyfleet open feat/x)'; sleep 5"
sleep 1.5
check_unless "$nobecome" 'attach via become renders' eval '_lazyfleet_tmux capture-pane -p -t "=attach:" | gq "app/feat-"'
_lazyfleet_tmux kill-session -t '=attach' 2>/dev/null

# outside tmux, the TUI comes back once the attached session ends
_lazyfleet_tmux new-session -d -s tui -x 100 -y 20 "env -u TMUX $ROOT/bin/lazyfleet; sleep 5"
check 'tui starts on windows when tmux has some' waitpane tui ' Windows '
_lazyfleet_tmux send-keys -t '=tui:' Tab
waitpane tui 'feat/x'; sleep 0.3
check 'tui fills in status after loading' retry '_lazyfleet_tmux capture-pane -p -t "=tui:" | gq "─ Worktrees ─"'
# sorted: feat/x first, then main
_lazyfleet_tmux send-keys -t '=tui:' j; sleep 0.3
_lazyfleet_tmux send-keys -t '=tui:' Enter
sleep 1
check_unless "$nobecome" 'tui enter attaches' eval '_lazyfleet_tmux list-clients -F "#S" | gq -x app'
_lazyfleet_tmux kill-session -t '=app'
check_unless "$nobecome" 'tui returns after session ends' waitpane tui Worktrees
check_unless "$nobecome" 'tui reselects the worktree it left' retry '_lazyfleet_tmux capture-pane -p -t "=tui:" | gq "▌ app  main"'
_lazyfleet_tmux kill-session -t '=tui' 2>/dev/null

# windows view: filter to the extra window, enter attaches to it, detach returns
_lazyfleet_tmux new-session -d -s tui -x 120 -y 20 "env -u TMUX $ROOT/bin/lazyfleet windows; sleep 5"
waitpane tui '1:extra'
_lazyfleet_tmux send-keys -t '=tui:' /; sleep 0.3
_lazyfleet_tmux send-keys -t '=tui:' -l 'app/feat-x 1:extra'; sleep 0.5
check 'find input takes a /' waitpane tui '> app/feat-x 1:extra'
_lazyfleet_tmux send-keys -t '=app/feat-x:1' 'echo live-$((6*7))' Enter
check 'window preview follows the pane' waitpane tui 'live-42'
_lazyfleet_tmux send-keys -t '=tui:' Enter; sleep 1
check_unless "$nobecome" 'windows enter attaches to that window' eval '_lazyfleet_tmux list-clients -F "#S #W" | gq -x "app/feat-x extra"'
_lazyfleet_tmux detach-client -s '=app/feat-x'
check_unless "$nobecome" 'windows view returns after detach' waitpane tui Windows
check_unless "$nobecome" 'windows view reselects the window it left' retry '_lazyfleet_tmux capture-pane -p -t "=tui:" | gq "▌ app/feat-x *1:extra"'
_lazyfleet_tmux kill-session -t '=tui' 2>/dev/null

# docker: a fake docker reporting two containers from feat/x, one from elsewhere
mkdir -p $SANDBOX/bin
cat >$SANDBOX/bin/docker <<EOF
#!/bin/sh
case \$1 in
  ps) printf '%s\t%s\t%s\t%s\n' $p web-1 'Up 5 minutes' id1 $p db-1 'Up 5 minutes' id2 /elsewhere x-1 'Up 1 hour' id3 ;;
  stop) shift; echo "\$@" >>$SANDBOX/docker-stopped ;;
esac
EOF
chmod +x $SANDBOX/bin/docker
path=($SANDBOX/bin $path)
check 'rows count docker containers' retry '_lazyfleet_rows -s -p | gq "^w	$p	.*🐳2"'
check 'rows without containers have no marker' eval '! _lazyfleet_rows -s -p | grep "^w	$repo	" | gq "🐳"'
check 'preview lists the containers' eval '_lazyfleet_preview w $p | gq "web-1"'
check 'containers_in matches by dir' eval '_lazyfleet_containers_in $p && (( $#reply == 2 ))'
_lazyfleet_tmux new-session -d -s uirm -x 160 -y 12 "zsh -fc 'path=($SANDBOX/bin \$path); source $ROOT/lazyfleet.zsh; _lazyfleet_ui_rm $p; sleep 3'"
waitpane uirm 'Remove worktree'
_lazyfleet_tmux send-keys -t '=uirm:' y
check 'rm warns about running containers' waitpane uirm '2 Docker container(s) from this worktree are running'
_lazyfleet_tmux send-keys -t '=uirm:' y
check 'rm stops the containers on yes' retry 'gq -sx "id1 id2" $SANDBOX/docker-stopped'
# keep feat/x: no to deleting the branch, no to removing despite its changes
waitpane uirm 'Also delete local branch'; _lazyfleet_tmux send-keys -t '=uirm:' n
waitpane uirm 'uncommitted changes'; _lazyfleet_tmux send-keys -t '=uirm:' n
sleep 0.3
_lazyfleet_tmux kill-session -t '=uirm' 2>/dev/null
check 'worktree kept after saying no' test -d $p

# pickers
git -C $repo branch -q feat/y
check 'branches lists free branches' eval '_lazyfleet_branches $repo | gq -x feat/y'
check 'branches skips checked-out ones' eval '! _lazyfleet_branches $repo | gq -xE "main|feat/x"'
other=$SANDBOX/src/api
mkdir -p $other && git -C $other init -q
check 'findrepos lists unregistered repos' eval 'LAZYFLEET_SEARCH=$SANDBOX/src _lazyfleet_findrepos | gq -x "~/src/api"'
check 'findrepos skips registered repos' eval '! LAZYFLEET_SEARCH=$SANDBOX/src _lazyfleet_findrepos | gq -x "~/src/app"'
mkdir -p $SANDBOX/elsewhere/api2 && git -C $SANDBOX/elsewhere/api2 init -q
print -l 'search=~/elsewhere' 'search_depth=2' '[app]' 'search=~/src' >$cfg
check 'search setting from config top' eval '_lazyfleet_findrepos | gq -x "~/elsewhere/api2" && ! _lazyfleet_findrepos | gq -x "~/src/api"'
check 'env var beats config setting' eval 'LAZYFLEET_SEARCH=$SANDBOX/src _lazyfleet_findrepos | gq -x "~/src/api"'
check 'section keys are not settings' eval '_lazyfleet_setting search_depth X 9 && [[ $REPLY == 2 ]] && _lazyfleet_setting nope X d && [[ $REPLY == d ]]'
print 'worktrees=~/wt2' >$cfg
check 'worktrees setting from config' eval 'LAZYFLEET_WORKTREES= lazyfleet new feat/cfg --no-open >/dev/null 2>/dev/null && test -d $SANDBOX/wt2/app/feat-cfg'
lazyfleet rm -f -D feat/cfg 2>/dev/null
rm $cfg
print -l ' search=~/elsewhere' ' [app/]' ' setup=' '  echo a' '    echo b' ' copy=go' >$cfg
check 'indented config: setting' eval '_lazyfleet_setting search X && [[ $REPLY == "~/elsewhere" ]]'
check 'indented config: multi-line value' eval '_lazyfleet_conf setup $p $repo && [[ $REPLY == $'"'"'echo a\n  echo b'"'"' ]]'
check 'indented config: next key ends value' eval '_lazyfleet_conf copy $p $repo && [[ $REPLY == go ]]'
rm $cfg
pick() {  # pick <query> <key>: run the picker on "alpha beta" in a pane, print REPLY
  rm -f $SANDBOX/pick.out
  _lazyfleet_tmux new-session -d -s pick -x 100 -y 15 \
    "zsh -fc 'source $ROOT/lazyfleet.zsh; print -l alpha beta | _lazyfleet_pick t p && print -r -- \$REPLY >$SANDBOX/pick.out'"
  sleep 0.8
  _lazyfleet_tmux send-keys -t '=pick:' -l -- $1
  sleep 0.3
  _lazyfleet_tmux send-keys -t '=pick:' $2
  waitfor $SANDBOX/pick.out && cat $SANDBOX/pick.out
  _lazyfleet_tmux kill-session -t '=pick' 2>/dev/null
}
check 'pick takes the match' test "$(pick bet Enter)" = beta
check 'pick takes typed name without match' test "$(pick zzz Enter)" = zzz
check 'pick ctrl-n takes typed name' test "$(pick al C-n)" = al

# TUI n: pick a new branch name, read the summary, any key opens its session
_lazyfleet_tmux new-session -d -s tui -x 120 -y 20 "env -u TMUX $ROOT/bin/lazyfleet; sleep 5"
waitpane tui ' Windows '
_lazyfleet_tmux send-keys -t '=tui:' Tab; waitpane tui 'feat/x'; sleep 0.3
_lazyfleet_tmux send-keys -t '=tui:' n; waitpane tui 'branch>'; sleep 0.3
_lazyfleet_tmux send-keys -t '=tui:' -l feat/e2e; sleep 0.3
_lazyfleet_tmux send-keys -t '=tui:' C-n
check_unless "$nobecome" 'tui n opens the new session right away' retry '_lazyfleet_tmux list-clients -F "#S" | gq -x app/feat-e2e'
_lazyfleet_tmux kill-session -t '=tui' 2>/dev/null
lazyfleet rm -f -D feat/e2e 2>/dev/null

# 6. rm
check 'rm refuses dirty without tty' eval '! lazyfleet rm feat/x </dev/null 2>/dev/null'
check 'rm refuses main worktree' eval '! lazyfleet rm $repo 2>/dev/null'
rmout=$(lazyfleet rm -f -D feat/x 2>&1)
check 'rm removes worktree' test ! -e $p
check 'rm says what it is doing' eval '[[ $rmout == *"Removing ~/wt/app/feat-x"*"… done"*"Deleting local branch feat/x… done"*"Closing tmux session app/feat-x"* ]]'
check 'rm kills session' eval '! _lazyfleet_tmux has-session -t "=app/feat-x" 2>/dev/null'
check 'rm deletes branch' eval '! git -C $repo show-ref -q --verify refs/heads/feat/x'

# unpushed-commit warning before deleting a branch
bare=$SANDBOX/origin.git
git init -q --bare $bare && git -C $repo remote add origin $bare && git -C $repo push -q origin main
check 'no warning for a branch at a pushed commit' eval '_lazyfleet_unpushed $repo feat/y && [[ -z $REPLY ]]'
up=$LAZYFLEET_WORKTREES/app/feat-u
lazyfleet new feat/u --no-open >/dev/null 2>/dev/null
git -C $up commit -q --allow-empty -m one
check 'warning for a never-pushed branch' eval '_lazyfleet_unpushed $up feat/u && [[ $REPLY == "feat/u was never pushed; deleting it drops its 1 commit"* ]]'
git -C $up push -q origin feat/u && git -C $up commit -q --allow-empty -m two && git -C $up commit -q --allow-empty -m three
check 'warning for commits not on origin' eval '_lazyfleet_unpushed $up feat/u && [[ $REPLY == "2 commits on feat/u aren'"'"'t on origin;"* ]]'
git -C $repo worktree lock --reason '{"build":"1","owner":"supacode","version":"0.10.8"}' $up
check 'lock owner is read from the reason' eval '_lazyfleet_locked $up && [[ $REPLY == "locked by supacode" ]]'
check 'rm refuses a locked worktree without tty' eval 'out=$(lazyfleet rm -D feat/u </dev/null 2>&1); (( $? )) && [[ $out == *"is locked by supacode (use -f)" ]] && test -d $up'
_lazyfleet_tmux new-session -d -s uirm -x 160 -y 10 "zsh -fc 'source $ROOT/lazyfleet.zsh; _lazyfleet_ui_rm $up; sleep 3'"
waitpane uirm 'Remove worktree'
check 'rm prompt shows ~ paths' waitpane uirm 'Remove worktree ~/wt/app/feat-u?'
_lazyfleet_tmux send-keys -t '=uirm:' y
check 'rm prompt warns about unpushed commits' waitpane uirm 'Warning: 2 commits on feat/u'
check 'rm prompt says only the local branch goes' waitpane uirm 'Also delete local branch feat/u? (the remote is untouched)'
_lazyfleet_tmux send-keys -t '=uirm:' n
check 'rm prompt asks about the lock' waitpane uirm 'feat-u is locked by supacode. Remove anyway?'
_lazyfleet_tmux send-keys -t '=uirm:' y
# setup's untracked .setup-ran makes it dirty: that's still asked
waitpane uirm 'has uncommitted changes. Remove anyway?'
_lazyfleet_tmux send-keys -t '=uirm:' y
retry 'test ! -e $up'
check 'rm keeps the branch when told not to delete it' eval 'test ! -e $up && git -C $repo show-ref -q --verify refs/heads/feat/u'
_lazyfleet_tmux kill-session -t '=uirm' 2>/dev/null

# accepting the lock prompt still asks about uncommitted changes
lp=$LAZYFLEET_WORKTREES/app/feat-lockdirty
lazyfleet new feat/lockdirty --no-open >/dev/null 2>/dev/null
print dirty >$lp/dirty.txt
git -C $repo worktree lock --reason test $lp
_lazyfleet_tmux new-session -d -s uirm -x 160 -y 10 "zsh -fc 'source $ROOT/lazyfleet.zsh; lazyfleet rm $lp; sleep 3'"
waitpane uirm 'Remove anyway?'
_lazyfleet_tmux send-keys -t '=uirm:' y
check 'rm asks about changes after accepting the lock' waitpane uirm 'has uncommitted changes. Remove anyway?'
_lazyfleet_tmux send-keys -t '=uirm:' n
sleep 0.5
check 'rm keeps a locked dirty worktree when told no' test -e $lp/dirty.txt
_lazyfleet_tmux kill-session -t '=uirm' 2>/dev/null
lazyfleet rm -f $lp >/dev/null 2>&1

# pull fast-forwards a worktree to its upstream, and never merges
pl=$LAZYFLEET_WORKTREES/app/feat-pull clone=$SANDBOX/clone
git -C $repo push -q origin main:feat/pull
lazyfleet new feat/pull --no-open >/dev/null 2>&1
git clone -q -b feat/pull $bare $clone 2>/dev/null
git -C $clone commit -q --allow-empty -m upstream && git -C $clone push -q
check 'pull fast-forwards to the upstream' eval 'lazyfleet pull feat/pull >/dev/null 2>&1 && [[ $(git -C $pl log -1 --format=%s) == upstream ]]'
git -C $pl commit -q --allow-empty -m local
git -C $clone commit -q --allow-empty -m again && git -C $clone push -q
check 'pull refuses diverged branches' eval 'out=$(lazyfleet pull feat/pull 2>&1); (( $? )) && [[ $out == *"… failed"* && $(git -C $pl log -1 --format=%s) == local ]]'
check 'key p pulls the worktree' eval 'FZF_KEY=p FZF_LIST_LABEL=" Worktrees " _lazyfleet_key w $pl | gq "^execute(.* _ui_pull {2})+.*reload("'
check 'key p pulls in the background when fzf listens' eval 'FZF_SOCK=$SANDBOX/x.sock FZF_KEY=p FZF_LIST_LABEL=" Worktrees " _lazyfleet_key w $pl | gq "^execute-silent(.* _ui_pull {2})+.*reload("'
# background pull of the diverged branch: ⟳ on its row meanwhile, then git's
# error for fzf to show (no fzf listening here, so nothing gets the reload)
_lazyfleet_pulldir; pd=$REPLY
git() { [[ $3 == pull ]] && sleep 1; command git "$@" }
FZF_SOCK=$SANDBOX/x.sock _lazyfleet_ui_pull $pl
check 'background pull marks the row' eval '_lazyfleet_rows | gq "feat/pull.*⟳ pulling"'
unfunction git
check 'failed background pull keeps git'"'"'s error' retry '[[ ! -e $pd/${pl//\//%} && -s $pd/${pl//\//%}.err ]]'
check 'and has fzf show it' eval '_lazyfleet_pulled | gq "^execute(.* _ui_pullfail)+.*reload("'
check 'which clears it' eval '_lazyfleet_ui_pullfail </dev/null >/dev/null 2>&1; [[ -z $(_lazyfleet_pulled | grep pullfail) ]]'
check 'key p ignored in the windows view' test -z "$(FZF_KEY=p FZF_LIST_LABEL=' Windows ' _lazyfleet_key t x)"
lazyfleet rm -f -D feat/pull 2>/dev/null

# a second repo with an already registered name is refused (sessions and
# worktree dirs are keyed by name)
twin=$SANDBOX/elsewhere/app
mkdir -p $twin && git -C $twin init -q -b main && git -C $twin commit -q --allow-empty -m init
check 'add refuses a second repo with the same name' eval 'out=$(lazyfleet add $twin 2>&1); (( $? )) && [[ $out == *"a repo named app is already registered"* ]] && ! lazyfleet repos | gq -x $twin'
check 'new in an unregistrable repo creates nothing' eval '! lazyfleet new -r $twin feat/twin --no-open >/dev/null 2>&1 && test ! -e $LAZYFLEET_WORKTREES/app/feat-twin && ! git -C $twin show-ref -q --verify refs/heads/feat/twin'

# names that map to the same session name clash too; a dotted name still
# counts its (dashed) sessions as live
dot=$SANDBOX/x/web.app dash=$SANDBOX/y/web-app
for d in $dot $dash; do mkdir -p $d && git -C $d init -q -b main && git -C $d commit -q --allow-empty -m init; done
lazyfleet add $dot >/dev/null
check 'add refuses a name that is the same as a session name' eval '! lazyfleet add $dash >/dev/null 2>&1 && ! lazyfleet repos | gq -x $dash'
_lazyfleet_tmux new-session -d -s web-app
check 'a dotted repo name shows its live session' eval '_lazyfleet_rows -p | grep -F "$dot" | gq "●"'
_lazyfleet_tmux kill-session -t '=web-app'
lazyfleet forget web.app >/dev/null

# every setup run gets its own script, even when session names map to the same file name
_lazyfleet_setup_run api/feat-x $SANDBOX 'print one'
_lazyfleet_setup_run api-feat/x $SANDBOX 'print two'
check 'setup scripts are per run' eval 'scripts=($TMPDIR/lazyfleet-$UID/api-feat-x.setup.*(N)); (( $#scripts == 2 )) && gq -x "print one" $scripts[1] $scripts[2] && gq -x "print two" $scripts[1] $scripts[2]'
_lazyfleet_tmux kill-session -t '=api/feat-x' 2>/dev/null; _lazyfleet_tmux kill-session -t '=api-feat/x' 2>/dev/null

# a POSIX $SHELL (dash has no `source`) still runs the setup script
if [[ -x /bin/dash ]]; then
  SHELL=/bin/dash _lazyfleet_setup_run dashtest $SANDBOX 'echo ran >~/dash.out'
  check 'setup runs under a POSIX-only shell' eval 'waitfor ~/dash.out && gq -x ran ~/dash.out'
  _lazyfleet_tmux kill-session -t '=dashtest' 2>/dev/null; rm -f ~/dash.out
fi

# setup sees the worktree's direnv env, which its prompt hook hasn't loaded yet
mkdir -p $HOME/bin
print -l '#!/bin/sh' '[ "$1 $2" = "export zsh" ] && echo "export LZS_DIRENV=loaded;"' >$HOME/bin/direnv
chmod +x $HOME/bin/direnv
print -r -- 'path=(~/bin $path)' >>$HOME/.zshrc
_lazyfleet_setup_run direnvtest $SANDBOX 'print -r -- $LZS_DIRENV >~/direnv.out'
check 'setup loads direnv first' eval 'waitfor ~/direnv.out && gq -x loaded ~/direnv.out'
_lazyfleet_tmux kill-session -t '=direnvtest' 2>/dev/null
rm -rf $HOME/bin ~/direnv.out

# rm -D reports a failed branch delete
lazyfleet new feat/lockref --no-open >/dev/null 2>&1
mkdir -p $repo/.git/refs/heads/feat && : >$repo/.git/refs/heads/feat/lockref.lock
check 'rm -D fails when the branch cannot be deleted' eval '! lazyfleet rm -f -D feat/lockref >/dev/null 2>&1 && test ! -e $LAZYFLEET_WORKTREES/app/feat-lockref && git -C $repo show-ref -q --verify refs/heads/feat/lockref'
rm -f $repo/.git/refs/heads/feat/lockref.lock; git -C $repo branch -q -D feat/lockref

# a planted temp dir (not ours, or a symlink) is refused, not used
check 'temp dir is private' eval '_lazyfleet_tmpdir && { m=$(command stat -f %Lp $REPLY 2>/dev/null) || m=$(command stat -c %a $REPLY); [[ $m == 700 ]] }'
mkdir -p $SANDBOX/evil
check 'a symlinked temp dir is refused' eval '(export TMPDIR=$SANDBOX/tmp2; mkdir -p $TMPDIR; ln -s $SANDBOX/evil $TMPDIR/lazyfleet-$UID; ! _lazyfleet_tmpdir 2>/dev/null)'

# d on a main worktree offers to forget the repo instead
lazyfleet add $other >/dev/null
_lazyfleet_tmux new-session -d -s uirm -x 120 -y 10 "zsh -fc 'source $ROOT/lazyfleet.zsh; _lazyfleet_ui_rm $other; sleep 3'"
waitpane uirm 'Forget api'
_lazyfleet_tmux send-keys -t '=uirm:' y
sleep 0.5
check 'd on main worktree forgets repo' eval '! lazyfleet repos | gq -x $other && test -d $other/.git'
_lazyfleet_tmux kill-session -t '=uirm' 2>/dev/null

# a ")" in a repo name can't add fzf actions
evil=$SANDBOX/z/'demo)+execute-silent(touch PWNED)+change-list-label(x'
mkdir -p $evil && git -C $evil init -q -b main && git -C $evil commit -q --allow-empty -m init
lazyfleet add $evil >/dev/null
_lazyfleet_tmux new-session -d -s tui -x 160 -y 20 -c $SANDBOX "env -u TMUX $ROOT/bin/lazyfleet; sleep 5"
waitpane tui ' Windows '
_lazyfleet_tmux send-keys -t '=tui:' Tab; waitpane tui ' Worktrees'
check 'a repo name with ")" is listed as it is' waitpane tui 'demo)+execute-silent(touch PWNED)+change-list-label(x'
check 'repo names and paths stay out of the action text' eval 'for k in enter c d n; do FZF_KEY=$k FZF_LIST_LABEL=" Worktrees " _lazyfleet_key w $evil; done | { ! gq PWNED }'
check 'a repo name with ")" runs nothing' eval 'sleep 0.5; [[ -z $(find $SANDBOX -name PWNED) ]]'
_lazyfleet_tmux kill-session -t '=tui' 2>/dev/null
lazyfleet forget $evil >/dev/null 2>&1

# a submodule or --separate-git-dir checkout keeps its metadata elsewhere:
# the main worktree is the checkout, not that metadata dir
sub=$SANDBOX/odd/sub super=$SANDBOX/odd/super sep=$SANDBOX/odd/sep
mkdir -p $sub && git -C $sub init -q -b main && git -C $sub commit -q --allow-empty -m init
mkdir -p $super && git -C $super init -q -b main && git -C $super -c protocol.file.allow=always submodule add -q $sub s 2>/dev/null
git -C $super/s worktree add -q $SANDBOX/odd/s-wt -b feat/s
git init -q -b main --separate-git-dir=$SANDBOX/odd/sep.git $sep
check 'main worktree of a submodule' eval '_lazyfleet_toplevel $super/s && [[ $REPLY == $super/s ]]'
check 'main worktree from a submodule worktree' eval '_lazyfleet_toplevel $SANDBOX/odd/s-wt && [[ $REPLY == $super/s ]]'
check 'main worktree of a --separate-git-dir checkout' eval '_lazyfleet_toplevel $sep && [[ $REPLY == $sep ]]'

# 7. forget
lazyfleet forget app
check 'forget unregisters' test -z "$(lazyfleet repos)"

print

finish
