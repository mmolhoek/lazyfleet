# lazyfleet

A tiny, shell-only take on [Supacode](https://supacode.sh): git worktrees, each with its own tmux session, driven from a lazygit-style TUI. It's pure zsh plus `git`, `tmux` and a recent `fzf` (tested with 0.74).

`●` means the worktree has a live tmux session, `*` means it has uncommitted changes, `↑n ↓m` shows ahead/behind upstream,
and `🐳n` counts running Docker containers started from it (by their compose working directory or devcontainer folder).
The Details pane lists those containers, and removing the worktree offers to stop them first.

## Install

With the install script, which puts the files in `~/.local/share/lazyfleet` and links `~/.local/bin/lazyfleet`
(it never edits your rc files, and tells you what to add):

```sh
curl -fsSL https://raw.githubusercontent.com/mmolhoek/lazyfleet/main/install.sh | sh
```

Run it again to update, or `curl -fsSL https://raw.githubusercontent.com/mmolhoek/lazyfleet/main/install.sh | sh -s -- uninstall`
to remove it. To pin a version, set `LAZYFLEET_VERSION=v1.2.3` (and `LAZYFLEET_SHA256` to verify the download), or a branch
name such as `main` or `feat/x` to try unreleased work (that install does not check for updates);
`LAZYFLEET_INSTALL_DIR` and `LAZYFLEET_BIN_DIR` change the locations. You need `zsh`, `git`, `tmux` and
`fzf` 0.58 or newer; the script warns about any that are missing.

Or from a checkout. lazyfleet itself is zsh, so zsh must be installed (it is on macOS), but it doesn't have to be your shell:

```sh
# ~/.zshrc (command + completion)
source /path/to/lazyfleet/lazyfleet.zsh
# ~/.bashrc (the command, without completion)
export PATH="/path/to/lazyfleet/bin:$PATH"
# ~/.config/fish/config.fish
fish_add_path /path/to/lazyfleet/bin
```

For a shorter command, add `alias lzs=lazyfleet`.

### Updates

An install from the install script looks for a newer release once a day, in the background (a single
request to github.com, which carries no data from lazyfleet). The TUI's title then reads
`lazyfleet · v1.2.3 available`, and quitting prints how to update: run the install command above again.
The installed version is always shown on the last line of the TUI's key help (with the update, when there is one),
at the top of `lazyfleet help`, and by `lazyfleet version`.
A checkout never checks. Turn it off with `update_check=off` (see Settings) or `LAZYFLEET_UPDATE_CHECK=off`.

To look right now instead of waiting for the daily check, run `lazyfleet update`. It asks GitHub in the foreground,
says whether you are up to date (or what to run to update), and works even when the daily check is off.

You can also bind a switcher popup in `~/.tmux.conf`:

```sh
bind w display-popup -E -w 80% -h 60% "/path/to/lazyfleet/bin/lazyfleet"
bind W display-popup -E -w 80% -h 60% "/path/to/lazyfleet/bin/lazyfleet windows"
```

## Use

```sh
lazyfleet                      TUI
lazyfleet add [path]           register a repo
lazyfleet forget [repo]        unregister a repo (files are kept)
lazyfleet repos                list registered repos
lazyfleet ls                   list worktrees with status
lazyfleet new <branch> [-r repo] [-b base] [--no-open]
lazyfleet open [worktree]      attach (outside tmux) or switch-client (inside tmux)
lazyfleet rm [worktree] [-f] [-D]   -f: even if dirty or locked (e.g. by Supacode); -D: delete the local branch
lazyfleet pull [worktree]      fast-forward to its upstream (git pull --ff-only)
lazyfleet windows              TUI on all tmux windows; enter switches to one
lazyfleet config [repo]        edit the settings, or a repo's own config file, in $VISUAL / $EDITOR (vi)
lazyfleet version              show the installed version
lazyfleet update               look for a newer release now
```

You can name a worktree by its path, its branch (`feat/x`), its session name (`app/feat-x`) or its directory name.

`new` reuses an existing local branch first, then tries `origin/<branch>`, and otherwise creates the branch from `-b base` (default `origin/HEAD`, then `HEAD`). New worktrees go to `<worktrees>/<repo>/<branch-slug>` (default `~/.lazyfleet/worktrees`; see [Settings](#settings)).

### TUI keys

| key         | Worktrees view                                                     | Repos view                 | Windows view       |
| ----------- | ------------------------------------------------------------------ | -------------------------- | ------------------ |
| `enter`     | open session                                                       | show this repo's worktrees | switch to window   |
| `n`         | new worktree in this row's repo: pick a branch, or type a new name | new worktree               |                    |
| `d`         | remove worktree (asks; optionally deletes the branch)              | forget repo                | kill window (asks) |
| `p`         | pull in the background (⟳ on its row); git's error if it fails     |                            |                    |
| `a`         | add repo: pick one found under your project dirs, or type a path   | add repo                   | add repo           |
| `tab` · `w` | next view · Windows view                                           |                            |                    |
| `c` · `C`   | edit the project config · the global settings                     | same                       | global settings     |
| `/` · `esc` | fuzzy filter · leave filter                                        |                            |                    |
| `r` · `q`   | reload · quit                                                      |                            |                    |

`lazyfleet` opens on the Windows view when tmux has any windows open, and on Worktrees otherwise. All lists are
sorted alphabetically.

The Windows view lists every tmux window in every session, with its command and directory, and previews what's on its
screen. `●` marks the window an attached client is showing.

Outside tmux, opening a worktree attaches to its session. When you detach (`prefix d`) or exit its last shell, you're back in the TUI.
Inside tmux, it switches the client and the TUI closes.

In the `n` and `a` pickers, Enter takes the highlighted entry. If nothing matches, Enter takes what you typed
(a new branch name or a path), and `ctrl-n` always takes what you typed.

## `.lazyfleet`

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

The setup is written to a script in `$TMPDIR/lazyfleet-$UID/` that first prints what lazyfleet did for the new
worktree (branch, copies, setup) and then runs the commands in order.

### Personal config

To set these keys without committing anything to the repo, give the repo its own file:
`~/.config/lazyfleet/projects/<repo-name>.conf`, with the same `key=value` lines. Press `c` on a repo or worktree
(or run `lazyfleet config <repo>`) to edit it. A missing file is created with a commented template, which also
shows the repo's `.lazyfleet` for reference. The project file wins over the repo's `.lazyfleet` files.

```
# ~/.config/lazyfleet/projects/app.conf
copy=.env .env.local
setup=npm ci
```

`[repo]` sections in `~/.config/lazyfleet/config` (the older layout) still work, between the project file and
`.lazyfleet` in precedence.

### Settings

Global settings go in `~/.config/lazyfleet/config` (`C` in the TUI, or `lazyfleet config`). An env var with the
same meaning wins when it's set.

| setting                                                    | env var                  | default                                                                                                            |
| ---------------------------------------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| `search`: where `a` looks for repos (space-separated dirs) | `LAZYFLEET_SEARCH`       | whichever of `~/Projects`, `~/code`, `~/src`, `~/dev`, `~/work`, `~/git`, `~/repos`, `~/workspace` exist, else `~` |
| `search_depth`: how deep `a` looks                         | `LAZYFLEET_SEARCH_DEPTH` | `4`                                                                                                                |
| `worktrees`: where new worktrees go                        | `LAZYFLEET_WORKTREES`    | `~/.lazyfleet/worktrees`                                                                                           |
| `status_branch`: `off` hides the branch in the status bar  | `LAZYFLEET_STATUS_BRANCH` | `on`                                                                                                              |
| `update_check`: `off` stops the daily check for a new release | `LAZYFLEET_UPDATE_CHECK` | `on`                                                                                                           |

```
search=~/Projects ~/work
search_depth=3
```

## State

- Registry: `~/.config/lazyfleet/repos`, one path per line.
- Settings: `~/.config/lazyfleet/config`; per-repo config: `~/.config/lazyfleet/projects/<repo>.conf` (see above).
- Session names: `<repo>` for the main worktree and `<repo>/<worktree-dir>` for the others.
- The sessions lazyfleet starts show the branch of the active pane's checkout at the start of their tmux
  `status-right` (followed by your global one, as it was when the session started). It follows checkouts,
  within `status-interval`.
- `LAZYFLEET_TMUX` overrides the tmux command (e.g. `tmux -L other`).

## Test

```zsh
zsh lazyfleet/tests/run.zsh       # the end-to-end suite (needs tmux and a recent fzf)
zsh lazyfleet/tests/update.zsh    # the update check
zsh lazyfleet/tests/install.zsh   # install.sh
```

The tests run in a throwaway HOME against an isolated tmux server.
