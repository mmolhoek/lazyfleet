# lazyspace

A tiny, shell-only take on [Supacode](https://supacode.sh): git worktrees, each with its own tmux session, driven from a lazygit-style TUI. It's pure zsh plus `git`, `tmux` and a recent `fzf` (tested with 0.74).

`●` means the worktree has a live tmux session, `*` means it has uncommitted changes, and `↑n ↓m` shows ahead/behind upstream.

## Install

```sh
# ~/.zshrc
source /path/to/lazyspace/lazyspace.zsh
```

For a shorter command, add `alias lzs=lazyspace`.

You can also bind a switcher popup in `~/.tmux.conf`:

```sh
bind w display-popup -E -w 80% -h 60% "/path/to/lazyspace/bin/lazyspace"
bind W display-popup -E -w 80% -h 60% "/path/to/lazyspace/bin/lazyspace windows"
```

## Use

```sh
lazyspace                      TUI
lazyspace add [path]           register a repo
lazyspace forget [repo]        unregister a repo (files are kept)
lazyspace repos                list registered repos
lazyspace ls                   list worktrees with status
lazyspace new <branch> [-r repo] [-b base] [--no-open]
lazyspace open [worktree]      attach (outside tmux) or switch-client (inside tmux)
lazyspace rm [worktree] [-f] [-D]
lazyspace run [worktree]       (re)start the run= command in tmux window "run"
lazyspace windows              TUI on all tmux windows; enter switches to one
```

You can name a worktree by its path, its branch (`feat/x`), its session name (`app/feat-x`) or its directory name.

`new` reuses an existing local branch first, then tries `origin/<branch>`, and otherwise creates the branch from `-b base` (default `origin/HEAD`, then `HEAD`). New worktrees go to `<worktrees>/<repo>/<branch-slug>` (default `~/.lazyspace/worktrees`; see [Settings](#settings)).

### TUI keys

| key         | Worktrees view                                                     | Repos view                 | Windows view       |
| ----------- | ------------------------------------------------------------------ | -------------------------- | ------------------ |
| `enter`     | open session                                                       | show this repo's worktrees | switch to window   |
| `n`         | new worktree in this row's repo: pick a branch, or type a new name | new worktree               |                    |
| `d`         | remove worktree (asks; optionally deletes the branch)              | forget repo                | kill window (asks) |
| `r`         | (re)start `run=` in window "run"                                   |                            |                    |
| `a`         | add repo: pick one found under your project dirs, or type a path   | add repo                   | add repo           |
| `tab` · `w` | next view · Windows view                                           |                            |                    |
| `/` · `esc` | fuzzy filter · leave filter                                        |                            |                    |
| `R` · `q`   | reload · quit                                                      |                            |                    |

`lazyspace` opens on the Windows view when tmux has any windows open, and on Worktrees otherwise. All lists are
sorted alphabetically.

The Windows view lists every tmux window in every session, with its command and directory, and previews what's on its
screen. `●` marks the window an attached client is showing.

Outside tmux, opening a worktree attaches to its session. When you detach (`prefix d`) or exit its last shell, you're back in the TUI.
Inside tmux, it switches the client and the TUI closes.

In the `n` and `a` pickers, Enter takes the highlighted entry. If nothing matches, Enter takes what you typed
(a new branch name or a path), and `ctrl-n` always takes what you typed.

## `.lazyspace`

This is an optional file in the repo root, made of `key=value` lines. It is read as data and never sourced. The new worktree's
copy takes precedence over the main one's.

```
setup=npm ci
run=npm run dev
copy=.env .env.local
```

- `setup`: typed into the first window of a newly created worktree's session.
- `run`: what `lazyspace run` / `r` starts in the `run` window. Running it again restarts it.
- `copy`: untracked files copied from the main worktree into new ones.

A value can span several lines: put each line after `key=`, indented. The first continuation line's indent is
stripped from all of them, so nested blocks keep their relative indent.

```
run=
  docker compose up -d db
  npm run migrate
  npm run dev
```

A multi-line `setup` or `run` is written to a script in `$TMPDIR/lazyspace-$UID/` and run with `source` in the
window's shell. That keeps your aliases and env, and later lines aren't typed into whatever an earlier one is running.

### Personal config

To set these keys without committing anything to the repo, put them in `~/.config/lazyspace/config` under a
section per repo. A section header is a repo name or a path (`~` works). These values win over the repo's
`.lazyspace` files.

```
[app]
run=npm run dev

[~/code/api]
run=go run ./cmd/api
setup=go mod download
```

### Settings

Global settings go at the top of `~/.config/lazyspace/config`, before any section. An env var with the same
meaning wins when it's set.

| setting                                                    | env var                  | default                                                                                                            |
| ---------------------------------------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| `search`: where `a` looks for repos (space-separated dirs) | `LAZYSPACE_SEARCH`       | whichever of `~/Projects`, `~/code`, `~/src`, `~/dev`, `~/work`, `~/git`, `~/repos`, `~/workspace` exist, else `~` |
| `search_depth`: how deep `a` looks                         | `LAZYSPACE_SEARCH_DEPTH` | `4`                                                                                                                |
| `worktrees`: where new worktrees go                        | `LAZYSPACE_WORKTREES`    | `~/.lazyspace/worktrees`                                                                                           |

```
search=~/Projects ~/work
search_depth=3

[app]
run=npm run dev
```

## State

- Registry: `~/.config/lazyspace/repos`, one path per line.
- Personal config: `~/.config/lazyspace/config` (see above).
- Session names: `<repo>` for the main worktree and `<repo>/<worktree-dir>` for the others.
- `LAZYSPACE_TMUX` overrides the tmux command (e.g. `tmux -L other`).

## Test

```zsh
zsh tests/run.zsh
```

The tests run in a throwaway HOME against an isolated tmux server.
