# `.claude`

Versioned configuration for [Claude Code](https://claude.com/claude-code).

Tracked here:

- `settings.json` — model, env, permissions, hook wiring
- `hooks/` — custom shell hooks
  - `branch-guard.sh` — auto-checkout a `claude/<slug>` branch on edits to `main`/`master`/`develop`/`trunk`
  - `notify.sh` — macOS notification on agent prompts/questions, with tmux pane jump on click
  - `jump-to-tmux.sh` — click handler used by `notify.sh`

Everything else under `~/.claude/` is runtime state (history, sessions, file-history, project memory, plugin registry) and is excluded via `.gitignore`.

## Use as a submodule

This repo is consumed as a submodule of [`dotfiles`](https://github.com/leo-leesco/dotfiles), under `.claude/`, and symlinked into `~/.claude/` via `stow`.
