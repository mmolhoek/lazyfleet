# lazyspace

A tiny, shell-only take on [Supacode](https://supacode.sh): git worktrees, each with its own
tmux session, driven from a lazygit-style TUI. It's pure zsh plus `git`, `tmux` and a recent `fzf` (tested with 0.74).

```
╭──────────── Worktrees ────────────╮╭─────────────── Details ───────────────╮
│ ▌ app  main        ●              ││ app/feat-login  ~/.lazyspace/workt…  │
│   app  feat/login  ● * ↑2         ││ ● session  0:zsh  1:run               │
│   api  main                       ││ ## feat/login...origin/feat/login     │
╰───────────────────────────────────╯│  M src/auth.ts                        │
╭───────────────────────────────────╮│                                       │
│ ↵ open  n new  a add  d del  r run││ a1b2c3d add login form                │
│ ⇥ repos  / find  R reload   q quit││ d4e5f6a wip                           │
╰───────────────────────────────────╯╰───────────────────────────────────────╯
```

`●` means the worktree has a live tmux session, `*` means it has uncommitted changes, and `↑n ↓m` shows ahead/behind upstream.

## Install

```zsh
# ~/.zshrc
source /path/to/lazyspace/lazyspace.zsh
```

For a shorter command, add `alias lzs=lazyspace`.

You can also bind a switcher popup in `~/.tmux.conf`:

```tmux
bind w display-popup -E -w 80% -h 60% "/path/to/lazyspace/bin/lazyspace"
```

## Use

```
lazyspace                      TUI
lazyspace add [path]           register a repo
lazyspace forget [repo]        unregister a repo (files are kept)
lazyspace repos                list registered repos
lazyspace ls                   list worktrees with status
lazyspace new <branch> [-r repo] [-b base] [--no-open]
lazyspace open [worktree]      attach (outside tmux) or switch-client (inside tmux)
lazyspace rm [worktree] [-f] [-D]
lazyspace run [worktree]       (re)start the run= command in tmux window "run"
```

You can name a worktree by its path, its branch (`feat/x`), its session name (`app/feat-x`) or its directory name.

`new` reuses an existing local branch first, then tries `origin/<branch>`, and otherwise creates the branch from
`-b base` (default `origin/HEAD`, then `HEAD`). New worktrees go to `$LAZYSPACE_WORKTREES/<repo>/<branch-slug>`
(default `~/.lazyspace/worktrees`).

### TUI keys

| key | Worktrees view | Repos view |
|---|---|---|
| `enter` | open session | show this repo's worktrees |
| `n` | new worktree (same repo) | new worktree |
| `d` | remove worktree (asks; optionally deletes the branch) | forget repo |
| `r` | (re)start `run=` in window "run" | |
| `a` | add repo | add repo |
| `tab` | switch view | switch view |
| `/` · `esc` | fuzzy filter · leave filter | |
| `R` · `q` | reload · quit | |

Outside tmux, opening a worktree attaches to its session. When you detach (`prefix d`) or exit its last shell, you're back in the TUI.
Inside tmux, it switches the client and the TUI closes.

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
