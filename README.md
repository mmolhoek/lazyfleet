# lazyspace

A tiny, shell-only take on [Supacode](https://supacode.sh): git worktrees, each with its own tmux session, driven from a lazygit-style TUI. It's pure zsh plus `git`, `tmux` and a recent `fzf` (tested with 0.74).

`●` means the worktree has a live tmux session, `*` means it has uncommitted changes, `↑n ↓m` shows ahead/behind upstream,
and `🐳n` counts running Docker containers started from it (by their compose working directory or devcontainer folder).
The Details pane lists those containers, and removing the worktree offers to stop them first.

## Install

lazyspace itself is zsh, so zsh must be installed (it is on macOS), but it doesn't have to be your shell:

```sh
# ~/.zshrc (command + completion)
source /path/to/lazyspace/lazyspace.zsh
# ~/.bashrc (the command, without completion)
export PATH="/path/to/lazyspace/bin:$PATH"
# ~/.config/fish/config.fish
fish_add_path /path/to/lazyspace/bin
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
lazyspace rm [worktree] [-f] [-D]   -f: even if dirty or locked (e.g. by Supacode); -D: delete the local branch
lazyspace pull [worktree]      fast-forward to its upstream (git pull --ff-only)
lazyspace windows              TUI on all tmux windows; enter switches to one
lazyspace config [repo]        edit the settings, or a repo's own config file, in $VISUAL / $EDITOR (vi)
```

You can name a worktree by its path, its branch (`feat/x`), its session name (`app/feat-x`) or its directory name.

`new` reuses an existing local branch first, then tries `origin/<branch>`, and otherwise creates the branch from `-b base` (default `origin/HEAD`, then `HEAD`). New worktrees go to `<worktrees>/<repo>/<branch-slug>` (default `~/.lazyspace/worktrees`; see [Settings](#settings)).

### TUI keys

| key         | Worktrees view                                                     | Repos view                 | Windows view       |
| ----------- | ------------------------------------------------------------------ | -------------------------- | ------------------ |
| `enter`     | open session                                                       | show this repo's worktrees | switch to window   |
| `n`         | new worktree in this row's repo: pick a branch, or type a new name | new worktree               |                    |
| `d`         | remove worktree (asks; optionally deletes the branch)              | forget repo                | kill window (asks) |
| `p`         | pull: fast-forward to its upstream (git's error if it can't)       |                            |                    |
| `a`         | add repo: pick one found under your project dirs, or type a path   | add repo                   | add repo           |
| `tab` · `w` | next view · Windows view                                           |                            |                    |
| `c` · `C`   | edit the project config · the global settings                     | same                       | global settings     |
| `/` · `esc` | fuzzy filter · leave filter                                        |                            |                    |
| `r` · `q`   | reload · quit                                                      |                            |                    |

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
copy=.env .env.local
```

- `setup`: run in the first window of a newly created worktree's session, through your interactive shell (so
  mise, direnv and aliases work). Questions your shell asks on entering the directory, such as a mise enter
  hook, come first and wait for you. The window then stays open as a normal shell. The setup is POSIX sh: under
  fish it runs as a `/bin/sh` child of the interactive fish (which still sets up mise and direnv, but not fish
  aliases).
- `copy`: untracked files copied from the main worktree into new ones.

A value can span several lines: put each line after `key=`, indented. The first continuation line's indent is
stripped from all of them, so nested blocks keep their relative indent.

```
setup=
  npm ci
  docker compose up -d db
  npm run migrate
```

The setup is written to a script in `$TMPDIR/lazyspace-$UID/` that first prints what lazyspace did for the new
worktree (branch, copies, setup) and then runs the commands in order.

### Personal config

To set these keys without committing anything to the repo, give the repo its own file:
`~/.config/lazyspace/projects/<repo-name>.conf`, with the same `key=value` lines. Press `c` on a repo or worktree
(or run `lazyspace config <repo>`) to edit it. A missing file is created with a commented template, which also
shows the repo's `.lazyspace` for reference. The project file wins over the repo's `.lazyspace` files.

```
# ~/.config/lazyspace/projects/app.conf
copy=.env .env.local
setup=npm ci
```

`[repo]` sections in `~/.config/lazyspace/config` (the older layout) still work, between the project file and
`.lazyspace` in precedence.

### Settings

Global settings go in `~/.config/lazyspace/config` (`C` in the TUI, or `lazyspace config`). An env var with the
same meaning wins when it's set.

| setting                                                    | env var                  | default                                                                                                            |
| ---------------------------------------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| `search`: where `a` looks for repos (space-separated dirs) | `LAZYSPACE_SEARCH`       | whichever of `~/Projects`, `~/code`, `~/src`, `~/dev`, `~/work`, `~/git`, `~/repos`, `~/workspace` exist, else `~` |
| `search_depth`: how deep `a` looks                         | `LAZYSPACE_SEARCH_DEPTH` | `4`                                                                                                                |
| `worktrees`: where new worktrees go                        | `LAZYSPACE_WORKTREES`    | `~/.lazyspace/worktrees`                                                                                           |

```
search=~/Projects ~/work
search_depth=3
```

## State

- Registry: `~/.config/lazyspace/repos`, one path per line.
- Settings: `~/.config/lazyspace/config`; per-repo config: `~/.config/lazyspace/projects/<repo>.conf` (see above).
- Session names: `<repo>` for the main worktree and `<repo>/<worktree-dir>` for the others.
- `LAZYSPACE_TMUX` overrides the tmux command (e.g. `tmux -L other`).

## Test

```zsh
zsh lazyspace/tests/run.zsh
```

The tests run in a throwaway HOME against an isolated tmux server.
