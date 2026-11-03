#!/usr/bin/env -S zsh -f
# Tests for stacked branches (lib/stack.zsh): the helpers that only look at
# stack entries, then the parent links in a real repo, lazyfleet new --on,
# lazyfleet stack (show, on, off, restack), the row marks, the preview and the
# s, S, r and P keys.

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
'Stack  2/3  (r or lazyfleet stack restack)
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
assert_contains 'conflict: and how to go on' 'git add them, then restack again: it continues the rebase' $out
assert_contains 'conflict: and that r does it file by file' 'r opens them for you to resolve' $out
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

# ============================================================================
# resolving a conflict
# ============================================================================

# a stack s1 ← s2 ← s3 where s2's two commits each change a file that s1
# changes too, so a restack of s2 stops twice: once per commit
_lazyfleet_new --no-open -q -r $repo s1 >/dev/null 2>&1
commit $W/s1 f1 one; commit $W/s1 f2 one
_lazyfleet_new --no-open -q -r $repo --on s1 s2 >/dev/null 2>&1
commit $W/s2 f1 two; commit $W/s2 f2 two
_lazyfleet_new --no-open -q -r $repo --on s2 s3 >/dev/null 2>&1
commit $W/s3 g three
commit $W/s1 f1 new; commit $W/s1 f2 new

# --- markers
print -l 'a' '<<<<<<< HEAD' 'x' '=======' 'y' '>>>>>>> 1234 msg' >$SANDBOX/m1
print -l 'a' '<<<<<<<' 'x' >$SANDBOX/m2
print -l 'a' '======= a heading underline is not a marker' '<<<<<<<< eight' >$SANDBOX/m3
check 'markers: a conflict has them' _lazyfleet_stack_markers $SANDBOX/m1
check 'markers: a bare one counts' _lazyfleet_stack_markers $SANDBOX/m2
check 'markers: look-alikes do not' not _lazyfleet_stack_markers $SANDBOX/m3
check 'markers: a file that is not there has none' not _lazyfleet_stack_markers $SANDBOX/nope

# --- without a terminal: it stops, and restack continues once files are added
out=$(_lazyfleet_stack restack $W/s1 2>&1); rc=$?
assert_eq 'stopped: restack fails' 1 $rc
assert_contains 'stopped: git says what conflicts' 'CONFLICT' $out
assert_contains 'stopped: a conflict is not called a failure' 'Restacking s2 onto s1… conflict' $out
check 'stopped: a rebase is under way' _lazyfleet_stack_rebasing $W/s2
check 'stopped: and none elsewhere' not _lazyfleet_stack_rebasing $W/s3
_lazyfleet_stack_unmerged $W/s2; assert_eq 'stopped: the file in conflict' f1 "$reply"
_lazyfleet_worktrees $repo
assert_contains 'stopped: the row still names the branch (HEAD is detached now)' "$W/s2${T}s2${T}0" "${(F)reply}"
_lazyfleet_stack_here $W/s2; assert_eq 'stopped: r on that row finds the branch' s2 $reply[2]
plain "$(_lazyfleet_stack_preview $W/s2)"
assert_contains 'stopped: the preview says so' '1 file(s) in conflict: r resolves them' $REPLY
out=$(_lazyfleet_stack restack $W/s1 2>&1); rc=$?
assert_eq 'stopped: restack again, unresolved, fails again' 1 $rc
assert_contains 'stopped: saying the same' 'the rebase of s2 stopped on a conflict' $out
check 'stopped: and leaves the rebase alone' _lazyfleet_stack_rebasing $W/s2
print -r -- two >$W/s2/f1 && git -C $W/s2 add f1
out=$(_lazyfleet_stack restack $W/s1 2>&1); rc=$?
assert_eq 'next conflict: restack stops on the next commit' 1 $rc
assert_contains 'next conflict: after continuing the rebase' 'Continuing the rebase of s2… next conflict' $out
_lazyfleet_stack_unmerged $W/s2; assert_eq 'next conflict: in the other file' f2 "$reply"
print -r -- two >$W/s2/f2 && git -C $W/s2 add f2
out=$(_lazyfleet_stack restack $W/s1 2>&1); rc=$?
assert_eq 'resolved: restack works' 0 $rc
assert_contains 'resolved: it finishes the rebase' 'Continuing the rebase of s2… done' $out
assert_contains 'resolved: and goes on up the stack' 'Restacking s3 onto s2… done' $out
check 'resolved: no rebase left' not _lazyfleet_stack_rebasing $W/s2
assert_eq 'resolved: s2 is on s1, with its own two commits' 2 "$(git -C $repo rev-list --count s1..s2)"
assert_eq 'resolved: s3 on s2, with its own one' 1 "$(git -C $repo rev-list --count s2..s3)"
for b in s2 s3; do st $b; assert_eq "resolved: $b is up to date" 0 $REPLY; done

# --- on a terminal (-i), without lazygit (the fallback; lazygit itself is
# tested below): file by file. A stand-in for the list of files
# answers from $answers ("edit <file> [editor]", "abort", "later"; an editor
# given becomes $EDITOR), and keeps what it showed in $offered and $notes.
# It runs in this shell, so restack does too (output to a file).
typeset -ga answers offered notes keys
_lazyfleet_stack_haslazygit() { false }
_lazyfleet_stack_pickfile() {
  local -a a
  offered+=("${(j:,:)@[4,-1]}") notes+=("$3")
  a=(${=answers[1]}); answers=("${(@)answers[2,-1]}")
  [[ -n $a[3] ]] && EDITOR=$a[3]
  reply=("${a[1]:-later}" "$a[2]")
}
_lazyfleet_readkey() { local k=$keys[1]; keys=("${(@)keys[2,-1]}"); [[ $k == y ]] }
print -l '#!/bin/sh' 'printf "merged\n" >"$1"' >$SANDBOX/ed && chmod +x $SANDBOX/ed
irestack() { _lazyfleet_stack_restack -i $1 >$SANDBOX/out 2>&1; rc=$?; out=$(<$SANDBOX/out) }
# both <worktree> <text>: one commit that writes the text to f3 and f4
both() { print -r -- $2 >$1/f3; print -r -- $2 >$1/f4; git -C $1 add f3 f4; git -C $1 commit -q -m "f3 f4: $2" }
both $W/s1 base
_lazyfleet_stack restack $W/s1 >/dev/null 2>&1
both $W/s2 mine
both $W/s1 theirs

offered=() notes=()
answers=("edit f3 true" "edit f3 $SANDBOX/ed" "edit f4 $SANDBOX/ed")
irestack $W/s1
assert_eq 'resolve: works' 0 $rc
assert_eq 'resolve: both files, again both (markers left), then the one left' 'f3,f4|f3,f4|f4' "${(j:|:)offered}"
assert_eq 'resolve: each round says how the last edit went' '|f3 still has conflict markers|f3 resolved' "${(j:|:)notes}"
assert_eq 'resolve: the edit is what was committed' merged "$(git -C $repo show s2:f3)"
assert_eq 'resolve: for both files' merged "$(git -C $repo show s2:f4)"
assert_contains 'resolve: the rebase is continued once none are left' 'Continuing the rebase of s2… done' $out
assert_contains 'resolve: and the stack restacked' 'Restacking s3 onto s2… done' $out
check 'resolve: git'"'"'s own conflict text is not printed over the list' eval '[[ $out != *CONFLICT* ]]'
for b in s2 s3; do st $b; assert_eq "resolve: $b is up to date" 0 $REPLY; done

# --- later: the rebase stays, and S goes on with it, from the stopped row
both $W/s1 again
offered=()
answers=(later)
irestack $W/s1
assert_eq 'later: restack fails' 1 $rc
assert_contains 'later: and says how to go on' 'the rebase of s2 is left in' $out
check 'later: the rebase is still there' _lazyfleet_stack_rebasing $W/s2
answers=("edit f3 $SANDBOX/ed" "edit f4 $SANDBOX/ed")
irestack $W/s2
assert_eq 'later: r on the stopped row finishes it' 0 $rc
assert_eq 'later: offering what is still in conflict' 'f3,f4|f3,f4|f4' "${(j:|:)offered}"
st s2; assert_eq 'later: s2 is up to date' 0 $REPLY

# --- abort: asks first; yes puts the branch back as it was
both $W/s1 once-more
s2tip=$(tip s2)
offered=()
answers=(abort abort) keys=(n y)
irestack $W/s1
assert_eq 'abort: fails' 1 $rc
assert_eq 'abort: a no to the question shows the list again' 2 $#offered
assert_contains 'abort: says so' 'the rebase of s2 is aborted' $out
check 'abort: no rebase left' not _lazyfleet_stack_rebasing $W/s2
assert_eq 'abort: s2 is as it was' $s2tip "$(tip s2)"
st s2; assert_eq 'abort: and still needs a restack' 1 $REPLY

# --- an editor that is not there
answers=("edit f3 /no/such/editor")
irestack $W/s1
assert_eq 'no editor: fails' 1 $rc
assert_contains 'no editor: and says so' "editor '/no/such/editor' not found" $out
git -C $W/s2 rebase --abort

# --- with lazygit: it runs in the worktree, and what it leaves decides what
# comes next. A stand-in that does what $LG_MODE says: resolve (and continue
# the rebase), stage (resolve, no continue), quit, or abort.
check 'lazygit: the fallback is used when it is not installed' eval '( unset "commands[lazygit]"; ! _lazyfleet_stack_haslazygit )'
unfunction _lazyfleet_stack_haslazygit
source $ROOT/lib/stack.zsh
_lazyfleet_stack_pickfile() { offered+=(called); reply=(later '') }
mkdir -p $SANDBOX/lgbin
cat >$SANDBOX/lgbin/lazygit <<'EOF'
#!/bin/sh
pwd >>"$LG_LOG"
resolve() { git diff --name-only --diff-filter=U | while read -r f; do echo merged >"$f"; git add "$f"; done; }
case $LG_MODE in
  resolve) resolve; GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 ;;
  stage) resolve ;;
  abort) git rebase --abort ;;
esac
EOF
chmod +x $SANDBOX/lgbin/lazygit
path=($SANDBOX/lgbin $path); rehash
export LG_LOG=$SANDBOX/lg.log
check 'lazygit: found when it is installed' _lazyfleet_stack_haslazygit

both $W/s1 lg-one
: >$LG_LOG; offered=()
LG_MODE=resolve irestack $W/s1
assert_eq 'lazygit: resolving in it works' 0 $rc
lg=$(<$LG_LOG)
assert_eq 'lazygit: it ran once, in the worktree of the branch' $W/s2 $lg
assert_eq 'lazygit: instead of the list' 0 $#offered
assert_eq 'lazygit: what it resolved was committed' merged "$(git -C $repo show s2:f3)"
assert_contains 'lazygit: the restack goes on up the stack' 'Restacking s3 onto s2… done' $out
for b in s2 s3; do st $b; assert_eq "lazygit: $b is up to date" 0 $REPLY; done

both $W/s1 lg-two
LG_MODE=stage irestack $W/s1
assert_eq 'lazygit: resolved but not continued works too' 0 $rc
assert_contains 'lazygit: lazyfleet continues the rebase' 'Continuing the rebase of s2… done' $out
st s2; assert_eq 'lazygit: and s2 is up to date' 0 $REPLY

both $W/s1 lg-three
LG_MODE=quit irestack $W/s1
assert_eq 'lazygit: quitting with conflicts left fails' 1 $rc
assert_contains 'lazygit: leaves the rebase for later' 'the rebase of s2 is left in' $out
check 'lazygit: it is still there' _lazyfleet_stack_rebasing $W/s2
: >$LG_LOG
LG_MODE=resolve irestack $W/s2
assert_eq 'lazygit: r on the stopped row opens it again, and finishes' 0 $rc
lg=$(<$LG_LOG)
assert_eq 'lazygit: once' $W/s2 $lg
st s2; assert_eq 'lazygit: s2 is up to date' 0 $REPLY

both $W/s1 lg-four
s2tip=$(tip s2) s3tip=$(tip s3)
LG_MODE=abort irestack $W/s1
assert_eq 'lazygit: aborting in it fails the restack' 1 $rc
assert_contains 'lazygit: and says so' 'the rebase of s2 was aborted; the branch is as it was' $out
check 'lazygit: no rebase left' not _lazyfleet_stack_rebasing $W/s2
assert_eq 'lazygit: s2 is as it was' $s2tip "$(tip s2)"
assert_eq 'lazygit: and s3 was left alone' $s3tip "$(tip s3)"
st s2; assert_eq 'lazygit: s2 still needs a restack' 1 $REPLY
path=(${path:#$SANDBOX/lgbin}); rehash
unset EDITOR
unfunction _lazyfleet_stack_pickfile _lazyfleet_readkey
source $ROOT/lib/stack.zsh; source $ROOT/lib/core.zsh

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
# what a branch changes: the Details pane, D and lazyfleet diff
# ============================================================================

_lazyfleet_new --no-open -q -r $repo d1 >/dev/null 2>&1; commit $W/d1 d1.txt "from d1"
_lazyfleet_new --no-open -q -r $repo --on d1 d2 >/dev/null 2>&1; commit $W/d2 d2.txt "from d2"

# --- what it is compared with
_lazyfleet_diffbase $repo d2; assert_eq 'base: a stacked branch, its parent' d1 $REPLY
_lazyfleet_diffbase $repo d1; assert_eq 'base: one outside a stack, the default branch' main $REPLY
check 'base: the default branch has none' not _lazyfleet_diffbase $repo main
git -C $repo branch d3 d1; git -C $repo config branch.d3.lazyfleetParent gone-branch
_lazyfleet_diffbase $repo d3; assert_eq 'base: a parent that is gone, the default branch' main $REPLY
git -C $repo update-ref refs/remotes/origin/main main
_lazyfleet_diffbase $repo d1; assert_eq 'base: origin'"'"'s copy of the default branch, when there is one' origin/main $REPLY
git -C $repo update-ref -d refs/remotes/origin/main
git -C $repo branch -q -D d3

# --- the Details pane: only the branch's own commits and files
plain "$(_lazyfleet_diff_preview $W/d2)"
assert_contains 'preview: says since what' '1 commit since d1' $REPLY
assert_contains 'preview: with the branch'"'"'s own commit' 'd2.txt: from d2' $REPLY
check 'preview: not its parent'"'"'s' eval '[[ $REPLY != *"d1.txt: from d1"* ]]'
assert_contains 'preview: the files it changes' 'd2.txt' $REPLY
check 'preview: none of the parent'"'"'s' eval '[[ $REPLY != *" d1.txt "* ]]'
assert_contains 'preview: and points at D' '(D: the diff in your pager)' $REPLY
assert_contains 'preview: with the diff under it' '+from d2' $REPLY
check 'preview: the diff is the branch'"'"'s own' eval '[[ $REPLY != *"+from d1"* ]]'
check 'preview: a diff that fits says no more' eval '[[ $REPLY != *"… more"* ]]'
plain "$(_LAZYFLEET_DIFF_LINES=3 _lazyfleet_diff_preview $W/d2)"
assert_contains 'preview: a longer diff is cut, and says so' '… more: D shows all of it' $REPLY
check 'preview: after that many lines' eval '[[ $REPLY != *"+from d2"* ]]'
check 'preview: the default branch has none (the plain log instead)' not _lazyfleet_diff_preview $repo
plain "$(_lazyfleet_preview_worktree $W/d2)"
assert_contains 'preview: part of the worktree preview' '1 commit since d1' $REPLY

# --- lazyfleet diff
print uncommitted >>$W/d2/d2.txt
out=$(_lazyfleet_diff $W/d2); rc=$?
assert_eq 'diff: works' 0 $rc
assert_contains 'diff: the branch'"'"'s own change' '+from d2' $out
assert_contains 'diff: uncommitted changes too' '+uncommitted' $out
check 'diff: not the parent'"'"'s' eval '[[ $out != *"from d1"* ]]'
out=$(_lazyfleet_diff $repo 2>&1); rc=$?
assert_eq 'diff: the default branch fails' 1 $rc
assert_contains 'diff: and says why' 'main is the default branch: there is nothing to compare it with' $out
git -C $W/d2 checkout -q -- d2.txt

# --- D: in the pager; a pager that does not wait gets a key to press
paused=0
_lazyfleet_pause() { (( paused++ )) }
out=$(GIT_PAGER=cat _lazyfleet_ui_diff $W/d2; print "paused=$paused"); rc=$?
assert_contains 'D: shows the diff' '+from d2' $out
assert_contains 'D: and waits after a pager that does not' 'paused=1' $out
git -C $repo branch d4 d2; git -C $repo config branch.d4.lazyfleetParent d2
git -C $repo worktree add -q $W/d4 d4
out=$(_lazyfleet_ui_diff $W/d4; print "paused=$paused")
assert_contains 'D: nothing to show says so' 'No changes since d2.' $out
assert_contains 'D: and waits' 'paused=1' $out
unfunction _lazyfleet_pause; source $ROOT/lib/core.zsh
LESS=FRX _lazyfleet_less_waits; assert_eq 'less: git'"'"'s FRX loses its F' RX $REPLY
( unset LESS; _lazyfleet_less_waits; print -r -- $REPLY ) | read -r r; assert_eq 'less: unset is git'"'"'s FRX, without F' RX $r
LESS='-R --quit-if-one-screen' _lazyfleet_less_waits; assert_eq 'less: the long option goes too' '-R ' $REPLY
LESS=-iR _lazyfleet_less_waits; assert_eq 'less: other options stay' -iR $REPLY

# ============================================================================
# a restack that loses a branch's work
# ============================================================================

# the case met in use: each branch adds a section at the end of one file;
# then the bottom one adds a line at its end. Restacking the middle one
# conflicts, and resolving it to the parent's side only drops its change.
lost() { git -C $repo rev-list --count refs/heads/$2..refs/heads/$1 }
_lazyfleet_new --no-open -q -r $repo l1 >/dev/null 2>&1; commit $W/l1 doc.md "first"
_lazyfleet_new --no-open -q -r $repo --on l1 l2 >/dev/null 2>&1; print second >>$W/l2/doc.md; git -C $W/l2 commit -q -am second
_lazyfleet_new --no-open -q -r $repo --on l2 l3 >/dev/null 2>&1; print third >>$W/l3/doc.md; git -C $W/l3 commit -q -am third
_lazyfleet_new --no-open -q -r $repo --on l3 l4 >/dev/null 2>&1
print another >>$W/l1/doc.md; git -C $W/l1 commit -q -am another
l2was=$(tip l2) l3was=$(tip l3)
_lazyfleet_stack restack $W/l1 >/dev/null 2>&1
check 'lost: the middle branch conflicts' _lazyfleet_stack_rebasing $W/l2
git -C $W/l2 checkout -q --ours doc.md && git -C $W/l2 add doc.md
out=$(_lazyfleet_stack restack $W/l1 2>&1); rc=$?
assert_eq 'lost: the restack stops' 1 $rc
assert_contains 'lost: and says the branch lost its work' 'l2 has no commits of its own any more (it had 1): their changes are gone.' $out
assert_contains 'lost: says the likely cause' 'b picks both' $out
assert_contains 'lost: and how to undo it' "reset --hard 'l2@{1}', then restack again" $out
assert_eq 'lost: l2 really is empty now' 0 "$(lost l2 l1)"
assert_eq 'lost: the branch above was not touched' $l3was "$(tip l3)"
check 'lost: so it is not stopped on a conflict either' not _lazyfleet_stack_rebasing $W/l3
# the undo it suggests, then the resolution that keeps both
git -C $W/l2 reset -q --hard 'l2@{1}'
assert_eq 'undo: l2 is back as it was' $l2was "$(tip l2)"
_lazyfleet_stack restack $W/l1 >/dev/null 2>&1
print -l first another second >$W/l2/doc.md && git -C $W/l2 add doc.md
out=$(_lazyfleet_stack restack $W/l1 2>&1); rc=$?
assert_eq 'undo: restacking with both sides kept works' 0 $rc
assert_contains 'undo: and the branch above goes on top without a conflict' 'Restacking l3 onto l2… done' $out
assert_eq 'undo: l2 kept its commit' 1 "$(lost l2 l1)"
assert_eq 'undo: l3 kept its own' 1 "$(lost l3 l2)"
check 'undo: an empty branch above (no commits yet) is no loss' eval '[[ $out != *"l4 has no commits"* ]]'

# when it was meant: the branch's change is in its parent already
commit $W/l3 meant.txt in-l3
git -C $W/l2 cherry-pick -x l2..l3 >/dev/null  # (-x: copies, not the same commits)
out=$(_lazyfleet_stack restack $W/l2 2>&1); rc=$?
assert_eq 'meant: a branch whose change is in its parent already stops once' 1 $rc
assert_contains 'meant: and says how to go on' 'If they were meant to go (they are in l2 already), restack again to go on.' $out
out=$(_lazyfleet_stack restack $W/l2 2>&1); rc=$?
assert_eq 'meant: restacking again goes on' 0 $rc
st l3; assert_eq 'meant: l3 is up to date' 0 $REPLY

# ============================================================================
# push
# ============================================================================

git init -q --bare $SANDBOX/origin.git
git -C $repo remote add origin $SANDBOX/origin.git
# remote <branch>: its commit on origin (nothing when it is not there)
remote() { git --git-dir=$SANDBOX/origin.git rev-parse -q --verify refs/heads/$1 }
_lazyfleet_new --no-open -q -r $repo p1 >/dev/null 2>&1; commit $W/p1 p1.txt one
_lazyfleet_new --no-open -q -r $repo --on p1 p2 >/dev/null 2>&1; commit $W/p2 p2.txt one
_lazyfleet_new --no-open -q -r $repo --on p2 p3 >/dev/null 2>&1; commit $W/p3 p3.txt one
git -C $repo branch lone main
git -C $repo branch plain main
git -C $repo push -q origin main 2>/dev/null
_lazyfleet_new --no-open -q -r $repo --on lone q >/dev/null 2>&1; commit $W/q q.txt one

# --- what is pushed
_lazyfleet_push_branches $repo p1; assert_eq 'what: a branch with a stack on it takes the stack along' 'p1 p2 p3' "$reply"
_lazyfleet_push_branches $repo p3; assert_eq 'what: from the top, the whole stack, bottom up' 'p1 p2 p3' "$reply"
_lazyfleet_push_branches $repo q;  assert_eq 'what: with the branch it sits on, when that is no default branch' 'lone q' "$reply"
_lazyfleet_push_branches $repo main; assert_eq 'what: the default branch never takes stacks along' main "$reply"
_lazyfleet_push_branches $repo plain; assert_eq 'what: a branch without a stack is just itself' plain "$reply"
_lazyfleet_stack_link $repo p1 main
_lazyfleet_push_branches $repo p2; assert_eq 'what: a stack on the default branch leaves that out' 'p1 p2 p3' "$reply"

# --- a first push
out=$(_lazyfleet_push $W/p2 2>&1); rc=$?
assert_eq 'push: works' 0 $rc
assert_contains 'push: says what it pushes' 'Pushing p1, p2, p3… done' $out
for b in p1 p2 p3; do assert_eq "push: $b is on origin" "$(tip $b)" "$(remote $b)"; done
assert_eq 'push: and tracks it' origin/p2 "$(git -C $repo rev-parse --abbrev-ref p2@{u})"

# --- a stack that needs a restack is not pushed
commit $W/p1 p1.txt two
p2on=$(remote p2)
out=$(_lazyfleet_push $W/p3 2>&1); rc=$?
assert_eq 'stale: push fails' 1 $rc
assert_contains 'stale: and says what to do' 'p2 needs a restack first (r, or lazyfleet stack restack)' $out
assert_eq 'stale: before pushing anything' $p2on "$(remote p2)"

# --- after a restack: refused, and without a terminal it says how
_lazyfleet_stack restack $W/p1 >/dev/null 2>&1
out=$(_lazyfleet_push $W/p1 2>&1); rc=$?
assert_eq 'refused: push fails' 1 $rc
assert_contains 'refused: says origin refused it' 'Pushing p1, p2, p3… refused' $out
assert_contains 'refused: with git'"'"'s reason' 'non-fast-forward' $out
assert_contains 'refused: and how to go on' 'use --force to push with lease' $out
check 'refused: without git'"'"'s advice to pull' eval '[[ $out != *"git pull"* && $out != *hint:* ]]'
assert_eq 'refused: atomic, so p1 (a fast-forward) was not pushed either' "$(git -C $repo rev-parse 'p1~1')" "$(remote p1)"
out=$(_lazyfleet_push --force $W/p1 2>&1); rc=$?
assert_eq 'force: works' 0 $rc
assert_contains 'force: says so' 'Pushing p1, p2, p3 (force with lease)… done' $out
for b in p1 p2 p3; do assert_eq "force: $b is on origin" "$(tip $b)" "$(remote $b)"; done

# --- on a terminal (-i, as in the TUI) a refused push asks
_lazyfleet_readkey() { [[ $key == y ]] }
commit $W/p1 p1.txt three; _lazyfleet_stack restack $W/p1 >/dev/null 2>&1
out=$(key=n _lazyfleet_push -i $W/p3 2>&1); rc=$?
assert_eq 'ask: no keeps it refused' 1 $rc
assert_contains 'ask: it asked' 'Force-push with lease?' $out
check 'ask: nothing forced' eval '[[ $(remote p2) != $(tip p2) ]]'
out=$(key=y _lazyfleet_push -i $W/p3 2>&1); rc=$?
assert_eq 'ask: yes forces it' 0 $rc
assert_contains 'ask: with lease' '(force with lease)… done' $out
assert_eq 'ask: p3 is on origin' "$(tip p3)" "$(remote p3)"
out=$(key=y _lazyfleet_push -i $W/p3 2>&1); rc=$?
assert_eq 'ask: nothing new pushes fine, without asking' 0 $rc
check 'ask: no question' eval '[[ $out != *Force-push* ]]'

# --- someone else's commit on origin is never dropped: restack fetches (so the
# lease alone would let a forced push through); the push compares first
git clone -q $SANDBOX/origin.git $SANDBOX/other-clone 2>/dev/null
git -C $SANDBOX/other-clone checkout -q p3 && commit $SANDBOX/other-clone theirs.txt x && git -C $SANDBOX/other-clone push -q origin p3 2>/dev/null
theirs=$(remote p3)
commit $W/p1 p1.txt four; _lazyfleet_stack restack $W/p1 >/dev/null 2>&1
out=$(key=y _lazyfleet_push -i $W/p1 2>&1); rc=$?
assert_eq 'lease: the forced push fails' 1 $rc
assert_contains 'lease: says what it would drop' 'p3: '"${theirs[1,7]}"' theirs.txt: x' $out
assert_contains 'lease: and how to go on' 'Get them first' $out
assert_eq 'lease: their commit is still on origin' $theirs "$(remote p3)"
_lazyfleet_push_run $repo plain >/dev/null 2>&1
check 'run: a branch on its own' eval '[[ $(remote plain) == $(tip plain) ]]'

# --- O: the pull request of a stacked branch goes onto its parent
_lazyfleet_newpr_base $repo p2; assert_eq 'O: onto its parent' 'p1...p2' $REPLY
_lazyfleet_newpr_base $repo p1; assert_eq 'O: one on the default branch names it' 'main...p1' $REPLY
_lazyfleet_newpr_base $repo plain; assert_eq 'O: one that is not stacked: just the branch' plain $REPLY
git -C $repo branch r1 main
git -C $repo branch r2 r1; _lazyfleet_stack_link $repo r2 r1
out=$(_lazyfleet_newpr_base $repo r2 2>&1); rc=$?
assert_eq 'O: a parent that is not on origin fails' 1 $rc
assert_contains 'O: and says to push the stack' 'r1, which r2 is stacked on, is not on origin yet: push the stack first (P)' $out
git -C $repo branch feat/x-y main; git -C $repo branch 'feat/z' feat/x-y; _lazyfleet_stack_link $repo feat/z feat/x-y
git -C $repo update-ref refs/remotes/origin/feat/x-y feat/x-y
_lazyfleet_newpr_base $repo feat/z; assert_eq 'O: names with a slash' 'feat/x-y...feat/z' $REPLY

# --- the bases of pull requests
_lazyfleet_stack_misbased "p2${T}p1" "p3${T}p2" -- "p2${T}12${T}main" "p3${T}13${T}p2" "zz${T}14${T}main" "p2${T}x${T}main"
assert_eq 'misbased: only one onto the wrong branch (a bad number is no pull request)' "12${T}p2${T}main${T}p1" "${(j:|:)reply}"
_lazyfleet_stack_misbased --; assert_eq 'misbased: nothing to check' 0 $#reply
# a stand-in gh: answers $GH_PRS (as the --jq gives it), logs every call
gh() {
  print -r -- "$*" >>$SANDBOX/gh.log
  [[ $1 == api && $2 == -X ]] && return 0
  [[ -n $GH_FAIL ]] && return 1
  print -r -- $GH_PRS
}
GH_PRS="p2${T}me/app${T}12${T}main"$'\n'"p3${T}me/app${T}13${T}p2"$'\n'"p1${T}fork/app${T}14${T}dev"$'\n'"odd${T}ME/APP${T}15${T}ma"$'\e'"in"
_lazyfleet_stack_prbases me/app
assert_eq 'prbases: the repo'"'"'s own, any case; no forks; no control characters' "p2${T}12${T}main|p3${T}13${T}p2|odd${T}15${T}main" "${(j:|:)reply}"
: >$SANDBOX/gh.log
out=$(_lazyfleet_stack_fixbases $repo me/app '' p1 p2 p3 2>&1); rc=$?
assert_eq 'bases: works' 0 $rc
assert_contains 'bases: names the one that is off' '#12 p2: onto main, should be onto p1' $out
check 'bases: not the ones that are right' eval '[[ $out != *"#13"* ]]'
assert_contains 'bases: without a terminal, how to fix it' 'gh pr edit 12 --base p1' $out
check 'bases: and changes nothing' not gq -- '-X PATCH' $SANDBOX/gh.log
: >$SANDBOX/gh.log
out=$(key=y _lazyfleet_stack_fixbases $repo me/app 1 p1 p2 p3 2>&1)
assert_contains 'bases: on a terminal, it asks' 'Change their base?' $out
assert_contains 'bases: yes moves it' 'Moving #12 onto p1… done' $out
check 'bases: through the API' gq -F 'api -X PATCH repos/me/app/pulls/12 -f base=p1' $SANDBOX/gh.log
: >$SANDBOX/gh.log
out=$(key=n _lazyfleet_stack_fixbases $repo me/app 1 p1 p2 p3 2>&1)
check 'bases: no changes nothing' not gq -- '-X PATCH' $SANDBOX/gh.log
out=$(GH_FAIL=1 _lazyfleet_stack_fixbases $repo me/app 1 p1 p2 p3 2>&1); rc=$?
assert_eq 'bases: gh failing does not fail it' 0 $rc
assert_contains 'bases: but says so' 'could not check the bases of the pull requests (gh)' $out
out=$(GH_PRS="p2${T}me/app${T}12${T}p1" _lazyfleet_stack_fixbases $repo me/app 1 p1 p2 p3 2>&1)
assert_eq 'bases: all right, nothing said' '' $out
: >$SANDBOX/gh.log
out=$(_lazyfleet_stack_fixbases $repo me/app 1 plain 2>&1)
check 'bases: a branch outside a stack does not ask GitHub' eval '[[ ! -s $SANDBOX/gh.log ]]'

# --- after P: a GitHub origin (that pushes to the local one), pull request marks on
# (their commit taken in first, as one would)
git -C $repo fetch -q origin
git -C $W/p3 cherry-pick -x $theirs >/dev/null
git -C $repo remote set-url origin https://github.com/me/app.git
git -C $repo remote set-url --push origin $SANDBOX/origin.git
mkdir -p $SANDBOX/ghbin && print '#!/bin/sh' >$SANDBOX/ghbin/gh && chmod +x $SANDBOX/ghbin/gh
path=($SANDBOX/ghbin $path); rehash
: >$SANDBOX/gh.log
out=$(LAZYFLEET_PR_STATUS=on _lazyfleet_push -f $W/p2 2>&1); rc=$?
assert_eq 'push: works' 0 $rc
assert_contains 'push: then lists the pull request that is off' '#12 p2: onto main, should be onto p1' $out
assert_contains 'push: with how to fix it' 'gh pr edit 12 --base p1' $out
: >$SANDBOX/gh.log
out=$(LAZYFLEET_PR_STATUS=off _lazyfleet_push $W/p2 2>&1)
check 'push: with pull request marks off, it does not ask GitHub' eval '[[ ! -s $SANDBOX/gh.log ]]'
git -C $repo config --unset remote.origin.pushurl
git -C $repo remote set-url origin $SANDBOX/origin.git
path=(${path:#$SANDBOX/ghbin}); rehash
unfunction gh
unfunction _lazyfleet_readkey; source $ROOT/lib/core.zsh

# ============================================================================
# after GitHub merged the bottom of a stack, and rebased the rest itself
# ============================================================================

git -C $repo stash -q -u 2>/dev/null   # (the main worktree clean: main can be brought up to date)
gside=$SANDBOX/github-side
_lazyfleet_new --no-open -q -r $repo g1 >/dev/null 2>&1; commit $W/g1 g1.txt one
_lazyfleet_stack_link $repo g1 main
_lazyfleet_new --no-open -q -r $repo --on g1 g2 >/dev/null 2>&1; commit $W/g2 g2.txt one
_lazyfleet_new --no-open -q -r $repo --on g2 g3 >/dev/null 2>&1; commit $W/g3 g3.txt one
out=$(_lazyfleet_push $W/g1 2>&1); rc=$?
assert_eq 'github: the stack is pushed' 0 $rc
# GitHub's side: squash-merge g1 into main and delete it, rebase g2 and g3 onto
# main and force-push them (a clone of origin plays GitHub)
git clone -q $SANDBOX/origin.git $gside 2>/dev/null
old2=$(git -C $gside rev-parse origin/g2)
git -C $gside checkout -q main && git -C $gside merge -q --squash origin/g1 && git -C $gside commit -q -m 'g1 (#1)'
git -C $gside push -q origin main :g1 2>/dev/null
git -C $gside checkout -q -b g2 origin/g2 && git -C $gside rebase -q --onto main origin/g1 g2
git -C $gside checkout -q -b g3 origin/g3 && git -C $gside rebase -q --onto g2 $old2 g3
git -C $gside push -q -f origin g2 g3 2>/dev/null

# --- r: fetches, brings main up to date, sees g1 merged, moves g2 onto main
out=$(_lazyfleet_stack restack $W/g2 2>&1); rc=$?
assert_eq 'github r: works' 0 $rc
assert_contains 'github r: brings main up to date' 'main is brought up to date with origin' $out
assert_eq 'github r: really' "$(git -C $repo rev-parse origin/main)" "$(tip main)"
assert_contains 'github r: leaves the merged branch alone' 'g1 is merged: left as it is (lazyfleet prune removes it)' $out
assert_contains 'github r: sees the parent merged' 'g2: its parent g1 is merged, so it moves onto main' $out
assert_eq 'github r: g2 is stacked on main now' main "$(cfg g2)"
assert_eq 'github r: with only its own commit on main' 'g2.txt: one' "$(git -C $repo log --format=%s main..g2)"
assert_eq 'github r: g3 on g2, with only its own' 'g3.txt: one' "$(git -C $repo log --format=%s g2..g3)"

# --- P: refused (GitHub's g2 and g3 differ), forced; and once more after GitHub
# rewrote g3 again since the fetch: fetched, compared, pushed
git -C $gside checkout -q g3 && git -C $gside commit -q --amend --no-edit --date=now && git -C $gside push -q -f origin g3 2>/dev/null
_lazyfleet_readkey() { true }
out=$(_lazyfleet_push -i $W/g2 2>&1); rc=$?
assert_eq 'github P: works' 0 $rc
assert_contains 'github P: origin changed since the fetch' 'origin has changed' $out
assert_contains 'github P: only rewritten, so it pushes' 'origin only has the same changes, rewritten (GitHub rebased the stack?): pushing yours' $out
for b in g2 g3; do assert_eq "github P: $b on origin is the local one" "$(tip $b)" "$(remote $b)"; done
# someone pushed a real change to g3 on GitHub: never dropped
git -C $gside checkout -q g3 && commit $gside g3.txt theirs && git -C $gside push -q -f origin g3 2>/dev/null
commit $W/g2 g2.txt two; _lazyfleet_stack restack $W/g2 >/dev/null 2>&1
their3=$(remote g3)
out=$(_lazyfleet_push -i $W/g2 2>&1); rc=$?
assert_eq 'github P: a real change on origin stops it' 1 $rc
assert_contains 'github P: and names it' 'g3.txt: theirs' $out
assert_eq 'github P: which stays on origin' $their3 "$(remote g3)"
unfunction _lazyfleet_readkey; source $ROOT/lib/core.zsh

# --- merged: GitHub's word (the pull request cache) at the commit the branch is at
git -C $repo branch m1 main
_lazyfleet_pr_enabled() { true }
_lazyfleet_ghslug() { REPLY=me/app }
_lazyfleet_pr_read() { prs[me/app:m1]="5${T}merged${T}${T}u${T}t${T}$PRHEAD" }
PRHEAD=$(tip m1) _lazyfleet_stack_merged $repo m1; assert_eq 'merged: GitHub says so, at its commit' 0 $?
PRHEAD=0123abc _lazyfleet_stack_merged $repo m1; assert_eq 'merged: not at another commit (work after the merge)' 1 $?
unfunction _lazyfleet_pr_enabled _lazyfleet_ghslug _lazyfleet_pr_read; source $ROOT/lib/pr.zsh
check 'merged: a branch never pushed is not' not _lazyfleet_stack_merged $repo m1
check 'merged: one still on origin is not' not _lazyfleet_stack_merged $repo g2

# --- the pull request bases leave GitHub's moves alone: a pull request whose
# parent is merged (GitHub moved it onto main) is not put back onto that parent
gh() { print -r -- "$*" >>$SANDBOX/gh.log; [[ $2 == -X ]] && return 0; print -r -- $GH_PRS }
out=$(GH_PRS="g3${T}me/app${T}31${T}main" _lazyfleet_stack_fixbases $repo me/app '' g2 g3 2>&1)
assert_contains 'bases: a parent on origin is still asked for' '#31 g3: onto main, should be onto g2' $out
check 'github: g1 counts as merged (gone from origin, its change in main)' _lazyfleet_stack_merged $repo g1
git -C $repo config branch.g3.lazyfleetParent g1
out=$(GH_PRS="g3${T}me/app${T}31${T}main" _lazyfleet_stack_fixbases $repo me/app '' g3 2>&1)
assert_eq 'bases: one onto a merged parent is left as GitHub moved it' '' $out
_lazyfleet_stack_link $repo g3 g2
unfunction gh

# ============================================================================
# the keys
# ============================================================================

k() { FZF_KEY=$1 FZF_LIST_LABEL=" Worktrees " _lazyfleet_key ${2:-w} ${3-/some/path} }
check 's makes a new worktree stacked on this one' eval 'k s | gq "^become(printf .* newon {2})$"'
check 'S picks the parent' eval 'k S | gq "^execute(.* _ui_stackon {2})+change-list-label"'
check 'r restacks' eval 'k r | gq "^execute(.* _ui_restack {2})+change-list-label"'
check 'P pushes' eval 'k P | gq "^execute(.* _ui_push {2})+change-list-label"'
check 'R still reloads' eval 'k R | gq "^change-list-label( Worktrees · loading… )+reload(.* _rows)"'
check 'r reloads in the windows view' eval 'FZF_KEY=r FZF_LIST_LABEL=" Windows " _lazyfleet_key t "=a/b:1" | gq "^reload(.*_winrows)"'
check 'N does nothing any more' test -z "$(k N)"
for key in s S P; do
  check "$key does nothing in the windows view" test -z "$(FZF_LIST_LABEL=' Windows ' FZF_KEY=$key _lazyfleet_key t '=a/b:1')"
  check "$key keeps the path out of the action text" eval '! k $key w /x/PWNED | gq PWNED'
done
check 's, S, r and P are typed into the filter, not run, while it is shown' \
  eval '[[ $_LAZYFLEET_LETTERS == *,S,* && $_LAZYFLEET_LETTERS == *,s,* && $_LAZYFLEET_LETTERS == *,r,* && $_LAZYFLEET_LETTERS == *,P,* ]]'
check 'the footer names them' eval '[[ $_LAZYFLEET_FOOTER_WT == *"(s) new stacked on this"* && $_LAZYFLEET_FOOTER_WT == *"(S)tack on…"* && $_LAZYFLEET_FOOTER_WT == *"(r)estack"* && $_LAZYFLEET_FOOTER_WT == *"(P)ush"* && $_LAZYFLEET_FOOTER_WT == *"(D)iff"* ]]'
check 'D shows the diff' eval 'k D | gq "^execute(.* _ui_diff {2})$"'
check 'D does nothing in the windows view' test -z "$(FZF_LIST_LABEL=' Windows ' FZF_KEY=D _lazyfleet_key t '=a/b:1')"
check 'help names lazyfleet diff' eval '_lazyfleet_help | gq "lazyfleet diff \[worktree\]"'
check 'and reload under R' eval '[[ $_LAZYFLEET_FOOTER_WT == *"(R)eload"* && $_LAZYFLEET_FOOTER_WT != *"(r)eload"* ]]'
check 'the windows footer keeps (r)eload' eval '[[ $_LAZYFLEET_FOOTER_WIN == *"(r)eload"* ]]'
check 'the windows footer does not' eval '[[ $_LAZYFLEET_FOOTER_WIN != *restack* ]]'
# --- the prompts behind N and s, with a stand-in for the picker: it answers
# $pick, and keeps what it was offered in $offered
pick=
_lazyfleet_pick() { offered=$(cat); [[ -n $pick ]] && REPLY=$pick }
_lazyfleet_pause() { : }
pick=c
_lazyfleet_ui_stackon $W/a
check 'S: offers the other local branches' eval '(( ${${(f)offered}[(Ie)c]} && ${${(f)offered}[(Ie)main]} ))'
check 'S: but not the branch itself' eval '(( ! ${${(f)offered}[(Ie)a]} ))'
assert_eq 'S: and "(not stacked)" first' '(not stacked)' "${${(f)offered}[1]}"
assert_eq 'S: picking a branch stacks on it' c "$(cfg a)"
pick=a
_lazyfleet_ui_stackon $W/c 2>/dev/null
assert_eq 'S: a loop is refused there too' main "$(cfg c)"
git -C $repo branch spare main
pick=spare
_lazyfleet_ui_stackon $W/a 2>/dev/null
assert_eq 'S: picking another moves it there' spare "$(cfg a)"
pick='(not stacked)'
_lazyfleet_ui_stackon $W/a
check 'S: "(not stacked)" unstacks' not cfg a
pick=
_lazyfleet_ui_stackon $W/a; rc=$?
assert_eq 'S: escape changes nothing, fine' 0 $rc
check 'S: nothing' not cfg a
pick=e
_lazyfleet_ui_newon $W/c 2>/dev/null; rc=$?
assert_eq 's: makes the worktree' 0 $rc
assert_eq 's: REPLY is its path' $W/e $REPLY
assert_eq 's: stacked on the row'"'"'s branch' c "$(cfg e)"
check 's: starting from it' git -C $repo merge-base --is-ancestor refs/heads/c refs/heads/e

# --- the bottom of a new stack: asked to stack it on the default branch too
_lazyfleet_readkey() { local k=$keys[1]; keys=("${(@)keys[2,-1]}"); [[ $k == y ]] }
git -C $repo branch root1 main
keys=(y); out=$(_lazyfleet_stack_offer_root $repo root1; print "parent=$(cfg root1)")
assert_contains 'root: asks' 'root1 is stacked on nothing itself. Stack it on main too' $out
assert_contains 'root: yes stacks it on the default branch' 'parent=main' $out
git -C $repo branch root2 main
keys=(n); out=$(_lazyfleet_stack_offer_root $repo root2; print "parent=$(cfg root2)")
assert_contains 'root: no leaves it' 'parent=' $out
check 'root: really' not cfg root2
out=$(_lazyfleet_stack_offer_root $repo main)
assert_eq 'root: never for the default branch itself' '' $out
out=$(_lazyfleet_stack_offer_root $repo root1)
assert_eq 'root: never for a branch that is stacked already' '' $out
# through s: on a row whose branch is stacked on nothing
_lazyfleet_new --no-open -q -r $repo root3 >/dev/null 2>&1
keys=(y); pick=root4
_lazyfleet_ui_newon $W/root3 >/dev/null 2>&1
assert_eq 's: the new branch is stacked on the row'"'"'s' root3 "$(cfg root4)"
assert_eq 's: and the row'"'"'s on the default branch, when asked to' main "$(cfg root3)"
_lazyfleet_stack_load $repo; _lazyfleet_stack_pos root3 main $reply
assert_eq 's: so the bottom row gets its mark' 1/2 $REPLY
# through S: picking a parent that is stacked on nothing
git -C $repo branch root5 main; git -C $repo branch root6 root5
git -C $repo worktree add -q $W/root6 root6
keys=(n); pick=root5
_lazyfleet_ui_stackon $W/root6 >/dev/null 2>&1
assert_eq 'S: no stacks the branch, and leaves the one picked' root5 "$(cfg root6)"
check 'S: unstacked' not cfg root5
git -C $repo config --unset branch.root6.lazyfleetParent; git -C $repo config --unset branch.root6.lazyfleetParentRev
keys=(y); pick=root5
_lazyfleet_ui_stackon $W/root6 >/dev/null 2>&1
assert_eq 'S: the branch is stacked on the one picked' root5 "$(cfg root6)"
assert_eq 'S: and that one on the default branch, when asked to' main "$(cfg root5)"
unfunction _lazyfleet_readkey; source $ROOT/lib/core.zsh

check 'help names the command' eval '_lazyfleet_help | gq "lazyfleet stack \[show | on <parent> | off | restack\]"'
check 'help names new --on' eval '_lazyfleet_help | gq -- "--on parent"'
check 'help names push' eval '_lazyfleet_help | gq "lazyfleet push \[worktree\] \[-f\]"'

finish
