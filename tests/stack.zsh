#!/usr/bin/env -S zsh -f
# Tests for stacked branches (lib/stack.zsh): the helpers that only look at
# stack entries, then the parent links in a real repo, lazyfleet new --on,
# lazyfleet stack (show, on, off, restack), the row marks, the preview and the
# N, s and S keys.

ROOT=${0:A:h:h}
source ${0:A:h}/lib.zsh
need_tools git tmux
SANDBOX=${$(mktemp -d):A}
export HOME=$SANDBOX/home XDG_CONFIG_HOME=$SANDBOX/cfg LAZYFLEET_WORKTREES=$SANDBOX/wt TMPDIR=$SANDBOX/tmp
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p $HOME $TMPDIR $XDG_CONFIG_HOME/lazyfleet
unset TMUX LAZYFLEET_PR_STATUS
export LAZYFLEET_PR_STATUS=off LAZYFLEET_AGENT_ICONS=off LAZYFLEET_UPDATE_CHECK=off
export SHELL=${commands[zsh]}
use_tmux stack
print -r -- '' >$HOME/.zshrc
source $ROOT/lazyfleet.zsh
cleanup() { tmux_cleanup; rm -rf $SANDBOX }
trap cleanup EXIT

T=$'\t'
# plain <text>: REPLY=the text without colours
plain() { REPLY=$(print -rn -- $1 | sed $'s/\x1b\\[[0-9;]*m//g') }

# ============================================================================
# entries: no git
# ============================================================================

# --- parsing git config's lines
_lazyfleet_stack_parse \
  'branch.b.lazyfleetparent a' 'branch.b.lazyfleetparentrev 1111' \
  'branch.a.lazyfleetparent main' \
  'branch.v1.2.lazyfleetparent a' 'branch.v1.2.lazyfleetparentrev 2222' \
  'branch.feat/x.lazyfleetparentrev 3333'
assert_eq 'parse: one entry per branch with a parent, by name' \
  "a${T}main${T}|b${T}a${T}1111|v1.2${T}a${T}2222" "${(j:|:)reply}"
check 'parse: a rev without a parent is no entry' eval '(( ! ${reply[(I)feat/x*]} ))'
_lazyfleet_stack_parse
assert_eq 'parse: nothing stacked, nothing back' 0 $#reply
_lazyfleet_stack_parse 'branch.b.lazyfleetparent'
assert_eq 'parse: an empty parent is no entry' 0 $#reply

# --- staleness
_lazyfleet_stack_staleness abc abc; assert_eq 'staleness: on the parent'"'"'s tip' 0 $REPLY
_lazyfleet_stack_staleness def abc; assert_eq 'staleness: the parent moved on' 1 $REPLY
_lazyfleet_stack_staleness '' abc;  assert_eq 'staleness: the parent is gone' 2 $REPLY
_lazyfleet_stack_staleness def '';  assert_eq 'staleness: no rev recorded counts as moved' 1 $REPLY

# a stack main ← a ← b ← c, plus a fork a ← x, and y on a branch that is not
# stacked itself (feature)
E=("a${T}main${T}r${T}0" "b${T}a${T}r${T}1" "c${T}b${T}r${T}0" "x${T}a${T}r${T}2" "y${T}feature${T}r${T}0")

# --- chain
_lazyfleet_stack_chain c $E
assert_eq 'chain: bottom first, up to the branch' 'a b c' "$reply"
assert_eq 'chain: REPLY is what the bottom sits on' main $REPLY
_lazyfleet_stack_chain a $E; assert_eq 'chain: the bottom alone' a "$reply"
check 'chain: a branch without a parent fails' not _lazyfleet_stack_chain main $E
assert_eq 'chain: and leaves an empty reply' 0 $#reply
_lazyfleet_stack_chain p "p${T}q${T}r${T}0" "q${T}p${T}r${T}0"
assert_eq 'chain: a hand-made loop is not followed forever' 'q p' "$reply"

# --- kids and below
_lazyfleet_stack_kids a $E;    assert_eq 'kids: by name' 'b x' "$reply"
_lazyfleet_stack_kids c $E;    assert_eq 'kids: a top branch has none' 0 $#reply
_lazyfleet_stack_kids 'a*' $E; assert_eq 'kids: a name is not a pattern' 0 $#reply
_lazyfleet_stack_below a $E;   assert_eq 'below: parents before children' 'b x c' "$reply"
_lazyfleet_stack_below main $E; assert_eq 'below: from the default branch' 'a b x c' "$reply"

# --- position
_lazyfleet_stack_pos a main $E; assert_eq 'pos: the bottom' 1/3 $REPLY
_lazyfleet_stack_pos b main $E; assert_eq 'pos: the middle' 2/3 $REPLY
_lazyfleet_stack_pos c main $E; assert_eq 'pos: the top' 3/3 $REPLY
_lazyfleet_stack_pos x main $E; assert_eq 'pos: a fork has the height of the whole stack' 2/3 $REPLY
_lazyfleet_stack_pos y main $E; assert_eq 'pos: one branch on another branch is a stack' 1/1 $REPLY
check 'pos: one branch on the default branch is no stack' not _lazyfleet_stack_pos z main "z${T}main${T}r${T}0"
check 'pos: a branch with no parent has no mark' not _lazyfleet_stack_pos main main $E

# --- the row mark
_lazyfleet_stack_mark 2/3 0; plain $REPLY
assert_eq 'mark: the position' ▲2/3 $REPLY
_lazyfleet_stack_mark 2/3 1; plain $REPLY
assert_eq 'mark: ⟲ when it needs a restack' '▲2/3 ⟲' $REPLY
_lazyfleet_stack_mark 2/3 2; plain $REPLY
assert_eq 'mark: also when the parent is gone' '▲2/3 ⟲' $REPLY
_lazyfleet_stack_mark -p 1/2 0; assert_eq 'mark: plain' 'stack 1/2' $REPLY
_lazyfleet_stack_mark -p 1/2 1; assert_eq 'mark: plain, needing a restack' 'stack 1/2 restack' $REPLY
_lazyfleet_stack_mark -p 1/2 0; check 'mark: plain has no colours' eval '[[ $REPLY != *$'"'"'\e'"'"'* ]]'

# --- the tree in the preview
_lazyfleet_stack_tree b $E; plain ${(F)reply}
assert_eq 'tree: the whole stack, the branch marked, a restack and a gone parent named' \
'   main
   └ a
     └ b ← ⟲ restack
       └ c
     └ x ⟲ parent gone' $REPLY
_lazyfleet_stack_tree b $E
check 'tree: the branch itself is bold' eval '[[ ${(F)reply} == *$'"'"'\e[1mb\e[0m'"'"'* ]]'
check 'tree: no stack, no tree' not _lazyfleet_stack_tree main $E

# --- what restack does, in order
_lazyfleet_stack_order c $E;    assert_eq 'order: from a stacked branch, its whole stack' 'a b x c' "$reply"
_lazyfleet_stack_order main $E; assert_eq 'order: from the branch a stack sits on, what is on it' 'a b x c' "$reply"
check 'order: a branch with nothing to do with stacks fails' not _lazyfleet_stack_order lone $E

# ============================================================================
# a real repo
# ============================================================================

repo=$SANDBOX/src/app
git init -q -b main $repo
print base >$repo/f && git -C $repo add f && git -C $repo commit -q -m init
W=$LAZYFLEET_WORKTREES/app
# commit <worktree> <file> <text>: a commit that writes the text to the file
commit() { print -r -- $3 >$1/$2 && git -C $1 add $2 && git -C $1 commit -q -m "$2: $3" }
tip() { git -C $repo rev-parse refs/heads/$1 }
cfg() { git -C $repo config --get branch.$1.lazyfleetParent$2 }
st() { local e; _lazyfleet_stack_load $repo; e=${reply[(r)$1$T*]}; REPLY=${e##*$T} }

# --- new --on
out=$(_lazyfleet_new --no-open -r $repo a 2>&1)
commit $W/a a.txt one
out=$(_lazyfleet_new --no-open -r $repo --on a b 2>&1); rc=$?
assert_eq 'new --on: works' 0 $rc
assert_contains 'new --on: the branch starts from its parent' 'b (new, from a)' $out
assert_contains 'new --on: and the summary says it is stacked' 'stack   on a' $out
assert_eq 'new --on: the parent is recorded' a "$(cfg b)"
assert_eq 'new --on: as based on the parent'"'"'s tip' "$(tip a)" "$(cfg b Rev)"
check 'new --on: b really has a'"'"'s commit' git -C $repo merge-base --is-ancestor refs/heads/a refs/heads/b
commit $W/b b.txt one
_lazyfleet_new --no-open -q -r $repo --on=b c >/dev/null 2>&1
assert_eq 'new --on=: the = form works too' b "$(cfg c)"
commit $W/c c.txt one

out=$(_lazyfleet_new --no-open -r $repo --on a -b main d 2>&1); rc=$?
assert_eq 'new: -b and --on together fail' 1 $rc
assert_contains 'new: and say so' 'give -b or --on, not both' $out
out=$(_lazyfleet_new --no-open -r $repo --on nope d 2>&1); rc=$?
assert_eq 'new --on: an unknown parent fails' 1 $rc
assert_contains 'new --on: and says so' 'no local branch nope to stack on' $out
check 'new --on: before making a worktree' test ! -e $W/d

# --- linking by hand
_lazyfleet_stack_link $repo a main >/dev/null
assert_eq 'link: on the default branch' main "$(cfg a)"
out=$(_lazyfleet_stack_link $repo a a 2>&1); rc=$?
assert_eq 'link: a branch on itself is refused' 1 $rc
assert_contains 'link: and says so' 'cannot be stacked on itself' $out
out=$(_lazyfleet_stack_link $repo a c 2>&1)
assert_contains 'link: a loop is refused' 'c is stacked on a already: that would make a loop' $out
assert_eq 'link: and leaves the link as it was' main "$(cfg a)"
out=$(_lazyfleet_stack_link $repo a nope 2>&1)
assert_contains 'link: on a branch that does not exist is refused' 'no local branch nope' $out

# an existing branch that forked from a before a moved on is based on where
# the two meet, so it shows up as needing a restack
git -C $repo branch old a
commit $W/a a.txt two
_lazyfleet_stack_link $repo old a
assert_eq 'link: an existing branch is based on where it meets its parent' "$(git -C $repo rev-parse 'a~1')" "$(cfg old Rev)"
st old; assert_eq 'load: so it needs a restack' 1 $REPLY
st c;   assert_eq 'load: a branch on its parent'"'"'s tip is up to date' 0 $REPLY
st b;   assert_eq 'load: one whose parent moved on is not' 1 $REPLY

# --- what git does with the link
git -C $repo branch -m old older
assert_eq 'git branch -m: the link moves with the branch' a "$(cfg older)"
git -C $repo branch -q -D older
check 'git branch -D: the link goes with the branch' not cfg older

# --- show, off, on
out=$(_lazyfleet_stack show $W/b); plain $out
assert_eq 'show: the stack, from any of its worktrees' \
'Stack  2/3  (S or lazyfleet stack restack)
   main
   └ a
     └ b ← ⟲ restack
       └ c' $REPLY
out=$(cd $W/c && _lazyfleet_stack); plain $out
assert_contains 'show: is the default, in the worktree we are in' 'c ←' $REPLY
out=$(_lazyfleet_stack show $repo)
assert_eq 'show: says when the branch is not stacked' 'main is not part of a stack (lazyfleet stack on <parent>)' "$out"
out=$(_lazyfleet_stack off $W/a); rc=$?
assert_eq 'off: works' 0 $rc
assert_eq 'off: names the branch' 'a is no longer stacked' "$out"
check 'off: the link is gone' not cfg a
check 'off: the rev too' not cfg a Rev
out=$(_lazyfleet_stack off $W/a 2>&1)
assert_contains 'off: twice says it is not stacked' 'a is not stacked on anything' $out
out=$(_lazyfleet_stack on main $W/a)
assert_eq 'on: names the branch and its parent' 'a is stacked on main' "$out"
out=$(_lazyfleet_stack bogus 2>&1)
assert_contains 'stack: an unknown subcommand shows the usage' 'usage: lazyfleet stack' $out

# --- marks on the rows and in lazyfleet ls
out=$(_lazyfleet_ls)
assert_contains 'ls: the bottom' 'stack 1/3' "$(grep ' a ' <<<$out)"
assert_contains 'ls: the middle needs a restack' 'stack 2/3 restack' "$(grep ' b ' <<<$out)"
assert_contains 'ls: the top' 'stack 3/3' "$(grep ' c ' <<<$out)"
check 'ls: the main worktree has no mark' eval '[[ $(grep " main " <<<$out) != *stack* ]]'
row=$(_lazyfleet_rows -s | grep "$T$W/b$T")
plain $row
assert_contains 'rows: the mark, with the status rows' '▲2/3 ⟲' $REPLY
check 'rows: the first, quick rows ask git for no stacks' eval '[[ $(_lazyfleet_rows) != *▲* ]]'

# --- the preview
out=$(_lazyfleet_stack_preview $W/b); plain $out
assert_contains 'preview: a stack section' 'Stack  2/3' $REPLY
assert_contains 'preview: with the tree' '└ b ←' $REPLY
assert_eq 'preview: nothing for a branch that is not stacked' '' "$(_lazyfleet_stack_preview $repo)"
plain "$(_lazyfleet_preview_worktree $W/c)"
assert_contains 'preview: part of the worktree preview' 'Stack  3/3' $REPLY

# ============================================================================
# restack
# ============================================================================

# --- the whole stack, bottom up, in each branch's own worktree
out=$(_lazyfleet_stack restack $W/c 2>&1); rc=$?
assert_eq 'restack: works' 0 $rc
assert_contains 'restack: b first' 'Restacking b onto a… done' $out
assert_contains 'restack: then c' 'Restacking c onto b… done' $out
check 'restack: a was already up to date: not rebased' eval '[[ $out != *"Restacking a"* ]]'
check 'restack: b has a'"'"'s new commit' git -C $repo merge-base --is-ancestor refs/heads/a refs/heads/b
check 'restack: and c has b'"'"'s' git -C $repo merge-base --is-ancestor refs/heads/b refs/heads/c
assert_eq 'restack: b'"'"'s own commit came along' 'b.txt: one' "$(git -C $repo log -1 --format=%s refs/heads/b)"
assert_eq 'restack: no commit of b'"'"'s twice' 1 "$(git -C $repo log --oneline --format=%s a..b | grep -c 'b.txt')"
assert_eq 'restack: the worktree followed its branch' "$(tip c)" "$(git -C $W/c rev-parse HEAD)"
for b in a b c; do st $b; assert_eq "restack: $b is up to date afterwards" 0 $REPLY; done
assert_eq 'restack: the rev is the parent'"'"'s new tip' "$(tip b)" "$(cfg c Rev)"
out=$(_lazyfleet_stack restack $W/a 2>&1); rc=$?
assert_eq 'restack: again does nothing, fine' 0 $rc
assert_eq 'restack: and says nothing' '' $out

# --- uncommitted changes stop it before git does anything
commit $W/a a.txt three
print dirty >>$W/b/b.txt
out=$(_lazyfleet_stack restack $W/a 2>&1); rc=$?
assert_eq 'restack: uncommitted changes fail it' 1 $rc
assert_contains 'restack: and say where' 'b has uncommitted changes in' $out
check 'restack: and nothing was rebased' eval '[[ $(cfg b Rev) != $(tip a) ]]'
git -C $W/b checkout -q -- b.txt

# --- a conflict stops it, and restack goes on once it is resolved
commit $W/b a.txt "b's own"
commit $W/a a.txt "a's own"
ctip=$(tip c)
out=$(_lazyfleet_stack restack $W/a 2>&1); rc=$?
assert_eq 'conflict: restack fails' 1 $rc
assert_contains 'conflict: says where to resolve it' 'the rebase of b stopped on a conflict in' $out
assert_contains 'conflict: and how to go on' 'git rebase --continue' $out
check 'conflict: the rebase is left for the person' git -C $W/b rev-parse -q --verify REBASE_HEAD
assert_eq 'conflict: c was not touched' $ctip "$(tip c)"
print -r -- "resolved" >$W/b/a.txt
git -C $W/b add a.txt && GIT_EDITOR=true git -C $W/b rebase --continue >/dev/null 2>&1
out=$(_lazyfleet_stack restack $W/a 2>&1); rc=$?
assert_eq 'conflict: restack again works' 0 $rc
check 'conflict: b, rebased by hand, is only brought up to date' eval '[[ $out != *"Restacking b"* ]]'
assert_contains 'conflict: c goes on top of it' 'Restacking c onto b… done' $out
st b; assert_eq 'conflict: b is up to date' 0 $REPLY
st c; assert_eq 'conflict: so is c' 0 $REPLY

# --- a recorded rev that fell behind: an older commit of the branch's own
# history would replay the parent's commits too
commit $W/b b.txt two
git -C $repo config branch.c.lazyfleetParentRev $(tip main)
out=$(_lazyfleet_stack restack $W/c 2>&1); rc=$?
assert_eq 'old rev: restack still works' 0 $rc
assert_eq 'old rev: c has its own commit once' 1 "$(git -C $repo log --format=%s b..c | grep -c 'c.txt')"
assert_eq 'old rev: and nothing else' 1 "$(git -C $repo rev-list --count b..c)"

# --- a rev that is not in the branch's history (a rebase by hand elsewhere)
commit $W/b b.txt three
git -C $repo config branch.c.lazyfleetParentRev $(git -C $repo commit-tree -m stray $(git -C $repo rev-parse 'main^{tree}'))
out=$(_lazyfleet_stack restack $W/c 2>&1); rc=$?
assert_eq 'stray rev: restack still works' 0 $rc
assert_eq 'stray rev: c has only its own commit on b' 1 "$(git -C $repo rev-list --count b..c)"

# --- the upstream that restack picks, directly
assert_eq 'upstream: the recorded rev when it is right' "$(tip b)" "$(_lazyfleet_stack_upstream $repo c b $(tip b); print $REPLY)"
assert_eq 'upstream: where they meet when no rev is recorded' "$(git -C $repo merge-base b c)" "$(_lazyfleet_stack_upstream $repo c b ''; print $REPLY)"

# --- a stacked branch without a worktree
git -C $repo branch nowt c
_lazyfleet_stack_link $repo nowt c
commit $W/c c.txt two
out=$(_lazyfleet_stack restack $W/c 2>&1); rc=$?
assert_eq 'no worktree: restack fails' 1 $rc
assert_contains 'no worktree: and says how to make one' 'nowt has no worktree to rebase it in: lazyfleet new nowt' $out
git -C $repo branch -q -D nowt

# --- a parent that is gone (merged and deleted): onto the default branch
git -C $repo merge -q --no-edit refs/heads/b >/dev/null 2>&1 ||
  { git -C $repo checkout -q --theirs . && git -C $repo commit -q -am merge }
_lazyfleet_rm -f -D $W/b >/dev/null 2>&1
check 'gone: b and its link are gone' not cfg b
st c; assert_eq 'gone: c knows its parent is gone' 2 $REPLY
out=$(_lazyfleet_ls)
assert_contains 'gone: ls asks for a restack' 'restack' "$(grep ' c ' <<<$out)"
out=$(_lazyfleet_stack restack $W/c 2>&1); rc=$?
assert_eq 'gone: restack works' 0 $rc
assert_contains 'gone: and says where c goes' 'its parent b is gone, so it moves onto main' $out
assert_eq 'gone: c is stacked on main now' main "$(cfg c)"
check 'gone: and sits on main' git -C $repo merge-base --is-ancestor refs/heads/main refs/heads/c
assert_eq 'gone: with only its own commits on top' 'c.txt: two|c.txt: one' "$(git -C $repo log --format=%s main..c | paste -sd'|' -)"

# --- the default branch: origin/HEAD's, else main, else master
_lazyfleet_stack_trunk $repo; assert_eq 'trunk: main' main $REPLY
other=$SANDBOX/src/other
git init -q -b master $other && git -C $other commit -q --allow-empty -m init
_lazyfleet_stack_trunk $other; assert_eq 'trunk: else master' master $REPLY
git -C $other branch -m master dev
check 'trunk: none of those fails' not _lazyfleet_stack_trunk $other
git -C $other update-ref refs/remotes/origin/dev $(git -C $other rev-parse dev)
git -C $other symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/dev
_lazyfleet_stack_trunk $other; assert_eq 'trunk: origin/HEAD'"'"'s first' dev $REPLY

# ============================================================================
# the keys
# ============================================================================

k() { FZF_KEY=$1 FZF_LIST_LABEL=" Worktrees " _lazyfleet_key ${2:-w} ${3-/some/path} }
check 'N makes a new worktree on this one' eval 'k N | gq "^become(printf .* newon {2})$"'
check 's picks the parent' eval 'k s | gq "^execute(.* _ui_stackon {2})+change-list-label"'
check 'S restacks' eval 'k S | gq "^execute(.* _ui_restack {2})+change-list-label"'
for key in N s S; do
  check "$key does nothing in the windows view" test -z "$(FZF_LIST_LABEL=' Windows ' FZF_KEY=$key _lazyfleet_key t '=a/b:1')"
  check "$key keeps the path out of the action text" eval '! k $key w /x/PWNED | gq PWNED'
done
check 'N, s and S are typed into the filter, not run, while it is shown' \
  eval '[[ $_LAZYFLEET_LETTERS == *,N,* && $_LAZYFLEET_LETTERS == *,s,* && $_LAZYFLEET_LETTERS == *,S,* ]]'
check 'the footer names them' eval '[[ $_LAZYFLEET_FOOTER_WT == *"(N)ew on this"* && $_LAZYFLEET_FOOTER_WT == *"(s)tack on"* && $_LAZYFLEET_FOOTER_WT == *"(S) restack"* ]]'
check 'the windows footer does not' eval '[[ $_LAZYFLEET_FOOTER_WIN != *restack* ]]'
# --- the prompts behind N and s, with a stand-in for the picker: it answers
# $pick, and keeps what it was offered in $offered
pick=
_lazyfleet_pick() { offered=$(cat); [[ -n $pick ]] && REPLY=$pick }
_lazyfleet_pause() { : }
pick=c
_lazyfleet_ui_stackon $W/a
check 's: offers the other local branches' eval '(( ${${(f)offered}[(Ie)c]} && ${${(f)offered}[(Ie)main]} ))'
check 's: but not the branch itself' eval '(( ! ${${(f)offered}[(Ie)a]} ))'
assert_eq 's: and "(not stacked)" first' '(not stacked)' "${${(f)offered}[1]}"
assert_eq 's: picking a branch stacks on it' c "$(cfg a)"
pick=a
_lazyfleet_ui_stackon $W/c 2>/dev/null
assert_eq 's: a loop is refused there too' main "$(cfg c)"
git -C $repo branch spare main
pick=spare
_lazyfleet_ui_stackon $W/a 2>/dev/null
assert_eq 's: picking another moves it there' spare "$(cfg a)"
pick='(not stacked)'
_lazyfleet_ui_stackon $W/a
check 's: "(not stacked)" unstacks' not cfg a
pick=
_lazyfleet_ui_stackon $W/a; rc=$?
assert_eq 's: escape changes nothing, fine' 0 $rc
check 's: nothing' not cfg a
pick=e
_lazyfleet_ui_newon $W/c 2>/dev/null; rc=$?
assert_eq 'N: makes the worktree' 0 $rc
assert_eq 'N: REPLY is its path' $W/e $REPLY
assert_eq 'N: stacked on the row'"'"'s branch' c "$(cfg e)"
check 'N: starting from it' git -C $repo merge-base --is-ancestor refs/heads/c refs/heads/e

check 'help names the command' eval '_lazyfleet_help | gq "lazyfleet stack \[show | on <parent> | off | restack\]"'
check 'help names new --on' eval '_lazyfleet_help | gq -- "--on parent"'

finish
