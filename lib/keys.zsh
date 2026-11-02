# lazyfleet: The reference of the TUI's keys and marks: the ? screen and lazyfleet keys.
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.
#
# One table feeds both, and tests/keys.zsh checks it against the keys the TUI
# binds, so a new key cannot go without an explanation. A record is
# "section<TAB>key<TAB>what it does<TAB>more": section w (Worktrees view),
# t (Windows view) or m (the marks on rows); "more" is the longer explanation,
# a paragraph that the screens wrap.

typeset -ga _LAZYFLEET_KEYS=(
  # --- the Worktrees view
  $'w\t↵\topen the worktree\tSwitches to the worktree\'s tmux session (inside tmux) or attaches to it (outside), and creates it first when there is none. Outside tmux you come back to lazyfleet when you detach.'
  $'w\tn\tnew worktree\tPick a branch of this row\'s repo, or type a new name, and get a worktree of it with its own tmux session. A new branch starts from origin\'s default branch. The repo\'s copy= files are copied in and its setup= runs in the session.'
  $'w\tN\tnew worktree stacked on this one\tLike n, but the new branch starts from this row\'s branch and is stacked on it: lazyfleet remembers the parent, shows the stack, and r keeps the new branch on top of it.'
  $'w\td\tdelete the worktree\tRemoves the worktree and closes its session. It asks first, warns about uncommitted changes, commits that are on no remote, running agents and Docker containers, and offers to delete the local branch too. On a repo\'s main worktree it offers to forget the repo instead (its files stay).'
  $'w\tp\tpull\tFast-forwards the worktree to its upstream (git pull --ff-only, so it never merges), in the background: the row shows ⟳ pulling until it is done, and git\'s error when it fails.'
  $'w\tP\tpush (the whole stack)\tPushes the branch to origin and sets its upstream. A stacked branch takes the rest of its stack along, bottom up, in one all-or-nothing push. Not while the stack needs a restack (⟲). After a restack origin refuses the rewritten branches: P then asks to force-push with lease, which still never drops commits on origin that you have not fetched. Afterwards it checks the stack\'s open pull requests and offers to fix any whose base is not the branch below it.'
  $'w\te\teditor\tOpens the worktree in $VISUAL or $EDITOR, in a window named edit of its tmux session (made once, shown again after).'
  $'w\tg\tlazygit\tOpens lazygit in the worktree, in a window named lazygit of its tmux session.'
  $'w\to\topen the pull request\tOpens the pull request of the worktree\'s branch in the browser (needs gh and a GitHub origin).'
  $'w\tO\tnew pull request\tOpens GitHub\'s page for a new pull request of the branch; nothing is created until you submit it there. For a stacked branch the pull request goes onto its parent, so it shows only its own commits.'
  $'w\ts\tstack on…\tPick the branch this one is stacked on, or (not stacked) to take it out of its stack. Only the link is recorded: r does the rebasing.'
  $'w\tr\trestack\tRebases every branch of this row\'s stack onto its parent, bottom up, each in its own worktree, so each one has the latest of the branch below it. A conflict opens lazygit in that worktree (or, without lazygit, a list of the files to resolve in your editor). Nothing is rebased while a worktree has uncommitted changes. It stops when a branch is left with none of its own commits (a conflict resolved to the parent\'s side only drops them; in lazygit, b keeps both sides) and says how to undo that.'
  $'w\ta\tadd a project\tPick a git repo found under your project directories (the search= setting), or type a path, and register it: its worktrees show up in the list.'
  $'w\tw\twindows\tShows every tmux window instead of the worktrees.'
  $'w\t⇥\twindows\tTab switches between the Worktrees and the Windows view.'
  $'w\tc\tproject config\tEdits this row\'s project config in $EDITOR: copy= (files to copy into a new worktree) and setup= (what to run in its session).'
  $'w\tC\tglobal settings\tEdits lazyfleet\'s settings in $EDITOR: where to look for repos, where worktrees go, and what to switch off.'
  $'w\t/\tfind\tShows the find input: type to narrow the list (a repo or branch name). While it is shown, letters are typed, not keys.'
  $'w\tesc\tleave find\tHides the find input again; without it, esc quits.'
  $'w\tR\treload\tReads every worktree, its status and its marks again.'
  $'w\tq\tquit\tLeaves lazyfleet.'
  $'w\t?\tthese keys\tThis screen: every key, and what the marks on a row mean.'
  # --- the Windows view
  $'t\t↵\tswitch to the window\tSwitches to (or attaches to) the tmux window under the cursor.'
  $'t\td\tkill the window\tCloses the tmux window, after asking; what runs in it ends.'
  $'t\t⇥\tworktrees\tBack to the Worktrees view (w does the same).'
  $'t\tr\treload\tLists the tmux windows again (R does the same).'
  $'t\tC\tglobal settings\tEdits lazyfleet\'s settings (c does the same here).'
  $'t\t/\tfind\tType to narrow the list of windows.'
  $'t\tq\tquit\tLeaves lazyfleet.'
  $'t\t?\tthese keys\tThis screen, with the Windows view\'s keys first.'
  # --- the marks on a row
  $'m\t●\tlive tmux session\tThe worktree has a tmux session. In the Windows view: the window an attached tmux client is looking at.'
  $'m\t↑3 ↓2\tahead and behind\tCommits that are not on its upstream yet (↑) and commits of the upstream it does not have yet (↓), as of the last fetch.'
  $'m\t*\tuncommitted changes\tAt the end of a row: the worktree has changes that are not committed.'
  $'m\t🐳2\tDocker containers\tContainers that run from the worktree (its compose working directory, or a devcontainer folder). d offers to stop them.'
  $'m\t⟳ pulling\ta pull is running\tA background pull (p) of the worktree is under way.'
  $'m\t#42 ✓\tpull request, checks pass\tThe branch\'s open pull request and its CI: ✓ passing, ✗ failing, … running, no mark when it has no checks.'
  $'m\t#42 draft\tpull request in another state\tdraft, merged or closed: a pull request that is not open for review.'
  $'m\t▲2/3\tstacked branch\tThe second branch of a stack three high (1 is the bottom). The Details pane draws the whole stack.'
  $'m\t⟲\tneeds a restack\tThe branch below it has changed (an amended commit, a review fix) or is gone (merged): r rebases the stack.'
  $'m\t✻ ✦ π\tan agent runs here\tClaude Code (✻), Copilot CLI (✦) or oh my pi (π) runs in the worktree\'s session; ✻2 means two.'
  $'m\t✻! ✻✓ ✻…\twhat the agent is doing\tIt waits for you (!), has finished (✓) or is working (…). The tmux status segment (lazyfleet status) shows the same: "! app" for a session that needs you.'
  $'m\tv1.3.0\ta new release is out\tIn the border of the list, as "lazyfleet · v1.3.0 available": a newer lazyfleet is out. lazyfleet update --install gets it.'
)

# REPLY=key or mark $1, padded to 10 columns on the screen (a 🐳 takes two)
_lazyfleet_keys_pad() {
  local n=$(( 10 - ${(m)#1} ))
  (( n > 0 )) || n=0
  REPLY=$1${(l:n:)}
}

# REPLY=the title of section $1 (w, t or m)
_lazyfleet_keys_title() {
  case $1 in
    (w) REPLY='Worktrees view' ;;
    (t) REPLY='Windows view' ;;
    (m) REPLY='Marks on a row' ;;
  esac
}

# reply=(the lines of text $2, wrapped at $1 columns: at spaces, a word
# longer than a line on a line of its own)
_lazyfleet_wrap() {
  local w=$1 word line=
  reply=()
  for word in ${=2}; do
    if [[ -n $line ]] && (( ${#line} + 1 + ${#word} > w )); then
      reply+=($line); line=$word
    else
      line+=${line:+ }$word
    fi
  done
  [[ -n $line ]] && reply+=($line)
}

# reply=(the records of section $1, in table order)
_lazyfleet_keys_of() {
  local r
  reply=()
  for r in $_LAZYFLEET_KEYS; do [[ ${r%%$'\t'*} == $1 ]] && reply+=($r); done
}

# lazyfleet keys: every key of each view and every mark, with what it does
_lazyfleet_keys() {
  local s r
  local -a f
  for s in w t m; do
    _lazyfleet_keys_title $s
    print -r -- $'\e[1m'$REPLY$'\e[0m'
    _lazyfleet_keys_of $s
    for r in $reply; do
      f=("${(@ps:\t:)r}")
      _lazyfleet_keys_pad $f[2]
      print -r -- "  $REPLY $f[3]"
      _lazyfleet_wrap 66 $f[4]
      print -rl -- "             "${^reply}
    done
    print
  done
}

# The lines of the ? screen, for fzf: "number<TAB>display": the sections of
# view $1 (w, else t) first, then the other view, then the marks
_lazyfleet_keys_rows() {
  local s i r
  local -a order f
  [[ $1 == t ]] && order=(t w m) || order=(w t m)
  for s in $order; do
    _lazyfleet_keys_title $s
    print -r -- "-$s"$'\t\e[1;34m── '$REPLY$' ──\e[0m'
    for (( i = 1; i <= $#_LAZYFLEET_KEYS; i++ )); do
      r=$_LAZYFLEET_KEYS[i]
      [[ ${r%%$'\t'*} == $s ]] || continue
      f=("${(@ps:\t:)r}")
      _lazyfleet_keys_pad $f[2]
      print -r -- "$i"$'\t  \e[33m'"$REPLY"$'\e[0m '"$f[3]"
    done
  done
}

# The ? screen's preview of line $1 of _lazyfleet_keys_rows, wrapped at
# words to the preview's width (fzf's own wrap breaks words)
_lazyfleet_keyinfo() {
  local w=$(( ${FZF_PREVIEW_COLUMNS:-60} - 1 ))
  local -a f
  if [[ $1 == -* ]]; then
    _lazyfleet_keys_title ${1#-}
    print -r -- $'\e[1m'$REPLY$'\e[0m'
    print
    case ${1#-} in
      (w) _lazyfleet_wrap $w 'The keys of the list of worktrees, one row per worktree of every repo you added.' ;;
      (t) _lazyfleet_wrap $w 'The keys of the list of tmux windows (w or tab from the worktrees).' ;;
      (m) _lazyfleet_wrap $w 'What the marks after a branch name mean. The Details pane on the right shows more: the session'"'"'s windows, containers, the pull request, the stack, git status and the latest commits.' ;;
    esac
    print -rl -- $reply
    return 0
  fi
  [[ $1 == <1-> && -n $_LAZYFLEET_KEYS[$1] ]] || return 0
  f=("${(@ps:\t:)_LAZYFLEET_KEYS[$1]}")
  print -r -- $'\e[1;33m'$f[2]$'\e[0m  \e[1m'$f[3]$'\e[0m'
  print
  _lazyfleet_wrap $w $f[4]
  print -rl -- $reply
}

# The ? screen: the keys and marks in fzf, the selected one explained on the
# right; type to search, esc (or enter) goes back. $1: the view it came from.
_lazyfleet_ui_keys() {
  local bin=${(q)LAZYFLEET_DIR}/bin/lazyfleet
  _lazyfleet_keys_rows $1 | fzf --ansi --layout reverse --style full --no-sort \
    --delimiter '\t' --with-nth 2 --list-label ' Keys ' --preview-label ' What it does ' \
    --with-shell "${commands[zsh]:-/bin/zsh} -c" \
    --preview "$bin _keyinfo {1}" --preview-window right,55% --exact \
    --prompt 'find> ' --footer 'type to search (words, not letters)   ↑↓ move   esc back' \
    --pointer '▌' --gutter ' ' --bind 'enter:abort' >/dev/null
  return 0
}
