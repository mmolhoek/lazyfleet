# lazyfleet: The help and version commands.
# Loaded by lazyfleet.zsh, in that order; not meant to be sourced on its own.

_lazyfleet_help() {
  local v= tag
  _lazyfleet_version_label && v=" $REPLY"
  print -r -- "lazyfleet$v — git worktrees, each in its own tmux session"
  cat <<'EOF'

  lazyfleet                      open the TUI
  lazyfleet add [path]           register a repo
  lazyfleet forget [repo]        unregister a repo
  lazyfleet repos                list registered repos
  lazyfleet ls                   list worktrees with status
  lazyfleet new <branch> [-r repo] [-b base] [--no-open]
  lazyfleet new --pr <number> | --issue <number> [-r repo] [-b base] [--no-open]
                                 the same, for a pull request's branch or a branch named after an issue (needs gh)
                                 create a worktree (+ .lazyfleet copy/setup) and open it
  lazyfleet open [worktree]      attach/switch to a worktree's session
  lazyfleet rm [worktree] [-f] [-D]
                                 remove a worktree (-f: even if dirty, locked or with agents running,
                                 -D: delete its local branch too)
  lazyfleet pull [worktree]      fast-forward a worktree to its upstream
  lazyfleet prune [-n] [-y] [--keep-branches] [--no-fetch] [-r repo | --all]
                                 remove worktrees whose branch is merged (-n: only list them)
  lazyfleet windows              open the TUI on all tmux windows (enter switches)
  lazyfleet config [repo]        edit the settings, or a repo's copy=/setup= file, in $EDITOR
  lazyfleet status               tmux status segment: sessions whose agent waits (!) or is done (✓)
  lazyfleet hooks [install|uninstall|status]
                                 let Claude Code report what it is doing (edits settings.json,
                                 keeps a backup)
  lazyfleet doctor               check that zsh, git, tmux and fzf (and gh) are there and recent enough
  lazyfleet version              show the installed version
  lazyfleet update [--install]   look for a newer release now (otherwise once a day); --install installs it

.lazyfleet (repo root, key=value; indent lines to continue a value):
  setup=…  copy=file1 file2
~/.config/lazyfleet/projects/<repo>.conf: the same keys, for one repo (wins)
~/.config/lazyfleet/config: search=dirs  search_depth=n  worktrees=dir  status_branch=off  update_check=off  agent_icons=off  agent_notify=off  pr_status=off  trust_branch_config=on
EOF
  if _lazyfleet_update_available; then
    tag=$REPLY; _lazyfleet_update_hint
    print -r -- "
Update available: $tag. Update: $REPLY"
  fi
}

# lazyfleet version
_lazyfleet_versioncmd() {
  if _lazyfleet_version_label; then print -r -- "lazyfleet $REPLY"
  else print -r -- "lazyfleet (unknown version: not installed from a release)"; fi
}
