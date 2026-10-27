# lazyfleet

A tiny, shell-only take on [Supacode](https://supacode.sh): git worktrees, each with its own tmux session, driven from a lazygit-style TUI. It's pure zsh plus `git`, `tmux` and a recent `fzf` (tested with 0.74).

`●` means the worktree has a live tmux session, `↑n ↓m` shows ahead/behind upstream, `🐳n` counts running Docker containers
started from it (by their compose working directory or devcontainer folder), and a `*` at the very end of the row means it has
uncommitted changes.
The Details pane lists those containers, and removing the worktree offers to stop them first.

`✻` marks a running [Claude Code](https://claude.com/claude-code), `✦` a running
[GitHub Copilot CLI](https://github.com/features/copilot/cli) and `π` a running
[oh my pi](https://wener.me/notes/ai/agent/oh-my-pi) (`omp`), on the worktree and on the window it runs in. Two
sessions of one kind show a count (`✻2`). lazyfleet finds them by looking for a `claude`, `copilot` or `omp` process
below a tmux pane's shell, so it sees the usual ways of starting them (the native binary, the npm package run by
node or bun, `gh copilot`) and only those running in tmux. Turn the marks off with `agent_icons=off` (see Settings) or `LAZYFLEET_AGENT_ICONS=off`.

### What the agents are doing

After an icon, a second mark says what that kind of agent is doing, the most urgent one winning: `!` waiting for
you (a permission prompt), `✓` done, `…` working. Idle shows nothing extra (`✻!`, `π✓`, `✦…`).

Where the state comes from:

- **Hooks.** `lazyfleet hooks install` adds Claude Code hooks to `~/.claude/settings.json` (or
  `$CLAUDE_CONFIG_DIR`). It needs `jq`, keeps your own settings and hooks, and saves the original once as
  `settings.json.lazyfleet.bak`. `lazyfleet hooks uninstall` takes ours out again, `lazyfleet hooks status` says
  whether they are in. Any other agent can report the same way:
  `lazyfleet-hook <claude|copilot|omp> <working|waiting|done|idle|clear>` (from inside its tmux pane).
- **The screen.** Claude Code without hooks still shows `…` while a turn runs (lazyfleet looks for
  "esc to interrupt"), and a turn you interrupted with Esc is not left looking busy.
- Copilot CLI and omp show state only when something calls `lazyfleet-hook` for them.

Finished work in a pane you are looking at counts as seen, so `✓` only stays for what you have not looked at.

**Notifications.** Add the segment to your tmux status bar:

```tmux
set -g status-right '#(lazyfleet status) %H:%M'
```

It names the sessions whose agent waits for you (`! app`) or has finished (`✓ api`), and nothing when there are
none. It skips agents you can see right now. When an agent starts waiting or finishes, lazyfleet also refreshes
the status bars and shows a short tmux message (`✻ app needs you`) on clients that are in other sessions. Turn the
message off with `agent_notify=off` (or `LAZYFLEET_AGENT_NOTIFY=off`); the status segment stays.

### Pull requests and CI

Each worktree whose branch has a pull request shows it as `#42` after the branch, with the CI result next to it:
`✓` the checks pass, `✗` one failed, `…` they are still running. A draft shows `draft`, and a merged or closed
pull request `merged` or `closed`. A pull request without any checks shows a bare `#42`. The Details pane adds the
title, the state and the checks.

It needs [`gh`](https://cli.github.com) with a login, and a GitHub remote. lazyfleet asks GitHub in the background
(at most every 90 seconds, backing off when GitHub or the network fails), so the list never waits for it; rows
update when an answer comes in. Only open pull requests get their checks fetched, for at most 25 of them per
repository. Turn the marks off with `pr_status=off` (or `LAZYFLEET_PR_STATUS=off`).

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
at the top of `lazyfleet help`, and by `lazyfleet version`. An install of a branch shows its name instead
(`lazyfleet feat/x (branch)`) and never checks for updates.
A checkout never checks. Turn it off with `update_check=off` (see Settings) or `LAZYFLEET_UPDATE_CHECK=off`.

To look right now instead of waiting for the daily check, run `lazyfleet update`. It asks GitHub in the foreground,
says whether you are up to date (or what to run to update), and works even when the daily check is off.

`lazyfleet update --install` (or `-i`) then installs the release it found: it downloads that release's `install.sh`
and runs it on this installation, so it works only for a copy that `install.sh` put there. Anything else gets the way
to update it by hand.

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
lazyfleet new --pr <number> | --issue <number> [-r repo] [-b base] [--no-open]
lazyfleet open [worktree]      attach (outside tmux) or switch-client (inside tmux)
lazyfleet rm [worktree] [-f] [-D]   -f: even if dirty, locked (e.g. by Supacode) or with agents running; -D: delete the local branch
lazyfleet pull [worktree]      fast-forward to its upstream (git pull --ff-only)
lazyfleet prune [-n] [-y] [--keep-branches] [--no-fetch] [-r repo | --all]   remove worktrees whose branch is merged
lazyfleet windows              TUI on all tmux windows; enter switches to one
lazyfleet config [repo]        edit the settings, or a repo's own config file, in $VISUAL / $EDITOR (vi)
lazyfleet doctor               check that the tools lazyfleet needs are there and recent enough
lazyfleet version              show the installed version
lazyfleet update [--install]   look for a newer release now; --install installs it
```

### Doctor

When something does not work, `lazyfleet doctor` checks the machine. Each finding is `ok`, `warn` (a feature is
reduced, or may not work) or `FAIL` (lazyfleet cannot work), with a suggested command when there is one:

- `zsh`, `git`, `tmux` and `fzf` are installed and recent enough (fzf 0.58 or newer; an older zsh, git or tmux
  only warns, as those minimums are cautious);
- `curl` (update check), `gh` with a login (pull request marks, unless `pr_status=off`), and, when `claude` is
  installed, `jq` and the Claude Code hooks (agent state);
- the version of this install, and registered repositories whose directory is gone.

It exits with status 1 when anything failed, so it can be used in scripts.

### Pruning merged worktrees

`lazyfleet prune` removes the worktrees (and, unless you pass `--keep-branches`, their local branches) whose work is
already merged. It counts exactly two things as merged:

- GitHub says the branch's pull request was merged **and** the worktree is at the commit the pull request ended with
  (so squash merges work, and anything you did afterwards keeps the worktree);
- the branch's remote branch is gone (deleted after the merge) and all of its commits are in the default branch.

A merged worktree that has uncommitted changes, is locked, or has agents running in its session is listed as `keep`
with the reason and left alone. It never touches the main worktree or a worktree that is not on a branch.

It runs `git fetch --prune` first (`--no-fetch` skips that), and asks GitHub when `gh` is set up (`pr_status=off` stops
that), then lists what it would remove and asks. `-n` only lists, `-y` does not ask (required without a terminal).
It works on the repository you are in, or on `-r <repo>` or `--all`.

`rm` asks first when the worktree has uncommitted changes, or when agents (Claude Code, Copilot, omp) are running in its tmux
session, since removing the worktree closes the session and ends them. Without a terminal it refuses instead; `-f` skips
the question. The TUI's delete key also offers to stop the worktree's Docker containers.

You can name a worktree by its path, its branch (`feat/x`), its session name (`app/feat-x`) or its directory name.

`new --pr 123` makes a worktree of pull request 123's branch (fetching it first), and `new --issue 45` one on a new branch
named after the issue (`issue-45-fix-the-login-page`, cut at 40 characters, starting from the default branch or `-b`). Both
use `gh` (logged in) and a GitHub `origin`. A pull request from a fork has no branch in your repository, so it gets a local
branch `pr-123` with the pull request's commits. Neither writes anything to GitHub.

`new` reuses an existing local branch first, then tries `origin/<branch>`, and otherwise creates the branch from `-b base` (default `origin/HEAD`, then `HEAD`). New worktrees go to `<worktrees>/<repo>/<branch-slug>` (default `~/.lazyfleet/worktrees`; see [Settings](#settings)).

### TUI keys

| key         | Worktrees view                                                     | Windows view       |
| ----------- | ------------------------------------------------------------------ | ------------------ |
| `enter`     | open session                                                       | switch to window   |
| `n`         | new worktree in this row's repo: pick a branch, or type a new name |                    |
| `d`         | remove worktree (asks; optionally deletes the branch); on a repo's main worktree it offers to forget the repo | kill window (asks) |
| `p`         | pull in the background (⟳ on its row); git's error if it fails     |                    |
| `e`         | open the worktree in `$VISUAL` / `$EDITOR` (a window named `edit`)  |                    |
| `g`         | open lazygit in the worktree (a window named `lazygit`)            |                    |
| `o`         | open the worktree's pull request in the browser                    |                    |
| `O`         | open GitHub's page for a new pull request                          |                    |
| `a`         | add repo: pick one found under your project dirs, or type a path   | add repo           |
| `tab` · `w` | switch between Worktrees and Windows · Windows view                | back to Worktrees  |
| `c` · `C`   | edit the project config · the global settings                      | global settings    |
| `/` · `esc` | fuzzy filter (type a repo name to narrow the list) · leave filter  |                    |
| `r` · `q`   | reload · quit                                                      |                    |

`e` and `g` start the tool in a window of the worktree's own session (the session is created when it is not there) and
switch to it; pressing the key again shows the same window instead of starting a second one. `o` opens the link the
pull request marks know, so it needs the same setup (`gh`, a GitHub `origin`, `pr_status` on) and works from the
cached data, a moment after the marks appear. It uses `$BROWSER`, else `open` (macOS) or `xdg-open`, and only ever opens
`https://github.com/<owner>/<repo>/pull/<number>` links.

`O` opens GitHub's "create pull request" page for the worktree's branch; the
title and description are written on that page, and nothing is created by lazyfleet itself. It needs a GitHub `origin`
(not `gh`), and the branch must already be on `origin` (`git push -u origin <branch>`); the default branch is refused.
Choose "Create draft pull request" in the page's button menu if you want a draft.

`lazyfleet` opens on the Windows view when tmux has any windows open, and on Worktrees otherwise. All lists are
sorted alphabetically.

The Windows view lists every tmux window in every session, with its command and directory, and previews what's on its
screen. The status icons (`●` for the window an attached client is showing, then the agent marks) follow the session
name directly, and the other columns line up after them.

Outside tmux, opening a worktree attaches to its session. When you detach (`prefix d`) or exit its last shell, you're back in the TUI.
Inside tmux, it switches the client and the TUI closes.

In the `n` and `a` pickers, Enter takes the highlighted entry. If nothing matches, Enter takes what you typed
(a new branch name or a path), and `ctrl-n` always takes what you typed.

## `.lazyfleet`

This is an optional file in the repo root, made of `key=value` lines. It is read as data and never sourced, but `setup=` is a
command that runs on your machine. The new worktree's copy takes precedence over the main one's only when it says the same
thing: a branch can bring its own `.lazyfleet` (think `new --pr`), so a `setup=` or `copy=` that differs from the main
worktree's is skipped, and the summary says so. Set `trust_branch_config=on` to run those anyway. `copy=` entries must be
paths inside the repo (no leading `/`, no `..`).

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
| `agent_icons`: `off` hides the `✻` `✦` `π` agent marks | `LAZYFLEET_AGENT_ICONS` | `on`                                                                                                           |
| `agent_notify`: `off` stops the tmux message when an agent needs you or is done | `LAZYFLEET_AGENT_NOTIFY` | `on`                                                                                              |
| `pr_status`: `off` hides the `#42 ✓` pull request and CI marks | `LAZYFLEET_PR_STATUS` | `on`                                                                                                           |
| `trust_branch_config`: `on` runs `setup=`/`copy=` from a branch's own `.lazyfleet` even when it differs from the main worktree's | `LAZYFLEET_TRUST_BRANCH_CONFIG` | `off` |

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
- Agent state: one small file per agent and pane in `~/.cache/lazyfleet/agents` (`LAZYFLEET_AGENT_DIR` moves
  it). Files of agents that have stopped are removed.
- Pull request cache: one small file per repository in lazyfleet's temporary directory (`pr/`), refreshed in the
  background and safe to delete.
- `LAZYFLEET_TMUX` overrides the tmux command (e.g. `tmux -L other`).

## Code

`lazyfleet.zsh` loads the parts in `lib/`, one per concern, and holds the command dispatch and the completion setup.
`bin/lazyfleet` is the entry point that the TUI's key bindings run, and `bin/lazyfleet-hook` is the plain-sh script that
agents call.

| part               | what is in it                                                          |
| ------------------ | ---------------------------------------------------------------------- |
| `lib/core.zsh`     | tmux, temp files, the repo registry, worktrees and session names        |
| `lib/config.zsh`   | settings, and the lookup of `copy=` / `setup=`                          |
| `lib/sessions.zsh` | a worktree's tmux session: create, switch, attach, status               |
| `lib/agents.zsh`   | Claude Code / Copilot CLI / omp in tmux panes: state, marks, hooks      |
| `lib/pr.zsh`       | pull request and CI marks                                               |
| `lib/rows.zsh`     | the TUI's rows and previews, repo discovery, the picker                 |
| `lib/commands.zsh` | add, forget, ls, new, open, rm, pull, config                            |
| `lib/tui.zsh`      | the fzf driver, its keys and the prompts behind them                    |
| `lib/update.zsh`   | the version of this copy and the daily check for a new release          |
| `lib/doctor.zsh`   | `lazyfleet doctor`                                                      |
| `lib/prune.zsh`    | `lazyfleet prune`                                                       |

## Test

```zsh
zsh lazyfleet/tests/all.zsh             # every suite, with a summary (-v shows their output)
zsh lazyfleet/tests/all.zsh prune doctor  # just these
zsh lazyfleet/tests/prune.zsh           # or one suite on its own
```

The suites (`tests/*.zsh`) share their helpers in `tests/lib.zsh`. Most run real git and tmux; `run.zsh` also needs
fzf 0.58 or newer and says so, instead of failing check by check, when yours is older. GitHub Actions runs
`tests/all.zsh` on every push and pull request, plus `zsh -n` and shellcheck on the scripts.

| suite             | what it covers                                                                      |
| ----------------- | ----------------------------------------------------------------------------------- |
| `run`             | the end-to-end suite: commands and the TUI                                           |
| `update`          | the update check                                                                    |
| `install`         | `install.sh`                                                                        |
| `agents`          | the Claude / Copilot / omp marks                                                    |
| `agent-state`     | agent state: hook script, marks, status, notifications, hooks install               |
| `pr-status`       | pull request and CI marks (stub `gh`, no network)                                   |
| `doctor`          | `lazyfleet doctor` (stub tools, no network)                                         |
| `new-from-pr`     | `new --pr` / `--issue` (stub `gh`, local "GitHub")                                  |
| `branch-trust`    | which `.lazyfleet` a new worktree may take `setup=` and `copy=` from                |
| `prune`           | `lazyfleet prune` (local "GitHub", stub `gh`)                                       |
| `handoff`         | the `e`, `g` and `o` keys (stub tools, real tmux)                                   |
| `new-pr`          | the `O` key (stub browser, no network)                                              |
| `busy-rm`         | the warning before removing a worktree with agents running                          |
| `all-runner`      | `tests/all.zsh` itself                                                              |

The tests run in a throwaway HOME against an isolated tmux server.
