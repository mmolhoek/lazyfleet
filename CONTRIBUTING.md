# Contributing to lazyfleet

lazyfleet is plain zsh (plus a POSIX `sh` installer and hook script). Everything needed to work on it is a
checkout, `zsh`, `git`, `tmux` and fzf 0.66 or newer. Every change comes with tests; run them all before a pull request:

```zsh
zsh tests/all.zsh
```

## Code layout

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

## Conventions

- **Names.** Every function is `_lazyfleet_<what>`; a command `lazyfleet foo` is `_lazyfleet_foo`, and the
  internal commands that fzf runs through `bin/lazyfleet` start with an underscore (`lazyfleet _rows` runs
  `_lazyfleet_rows`). Constants are `_LAZYFLEET_UPPER`.
- **Results.** A function returns a value in `REPLY` (a string) or `reply` (an array), not on stdout, so a call
  costs no subshell. What it prints is for the person or for fzf. The success of a call is its exit status; on
  failure `REPLY` means nothing. `REPLY` is the caller's to copy at once: the next call may overwrite it.
- **Shared state.** A few functions fill an associative array that the caller declares with `local -A`, by name:
  `prs` (pull requests: `_lazyfleet_pr_read`, `_lazyfleet_prune_refresh`) and `agtally` (agent counts:
  `_lazyfleet_agent_tally`, read by `_lazyfleet_agent_marks_at`). The few globals that carry a second result are
  set where they are documented: `_lazyfleet_from`, `_lazyfleet_ignored` and `_lazyfleet_sect` (where a config
  value came from: `lib/config.zsh`), `_lazyfleet_sum` and `_lazyfleet_quiet` (the summary of `new`:
  `lib/commands.zsh`, `lib/sessions.zsh`), and doctor's counters. Anything new returns its results instead.
- **Options.** Every command runs with zsh's default options: `bin/lazyfleet` starts `zsh -f`, and
  `_lazyfleet_main` begins with `emulate -L zsh`. So a function starts with `emulate -L zsh` only when it changes
  an option (`setopt extended_glob`, say), which keeps the change to itself and the functions it calls.
- **Size.** Functions stay short (under about 45 lines): gather, decide and print are separate functions, and the
  parts without side effects (formatting a row, choosing a pull request, reading a config file) have unit tests.

## Tests

```zsh
zsh lazyfleet/tests/all.zsh             # every suite, with a summary (-v shows their output)
zsh lazyfleet/tests/all.zsh prune doctor  # just these
zsh lazyfleet/tests/prune.zsh           # or one suite on its own
```

The suites (`tests/*.zsh`) share their helpers in `tests/lib.zsh`. Most run real git and tmux; `run.zsh` also needs
fzf 0.66 or newer and says so, instead of failing check by check, when yours is older. GitHub Actions runs
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
| `helpers`         | the small helpers the commands share (worktree entries, settings, prompts)          |
| `core`            | reading git's own files: worktree entries (absolute and relative links), HEAD, session names |
| `window-preview`  | the Windows view's preview, including lazyfleet's own pane (real tmux)              |
| `all-runner`      | `tests/all.zsh` itself                                                              |

The tests run in a throwaway HOME against an isolated tmux server.
