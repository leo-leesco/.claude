#!/usr/bin/env bash
# Click handler for the Claude Code notification.
# Usage: jump-to-tmux.sh <session> <window> [<pane_id>]
# Switches every connected tmux client to <session>:<window>, focuses
# <pane_id> within that window when given, and brings WezTerm to the front.
# Robust to: no client connected (re-attaches in a new WezTerm window),
# multiple clients (switches all), tmux server not running.

set -u

session="${1:-}"
window="${2:-}"
pane_id="${3:-}"

[ -z "$session" ] && exit 0

TMUX_BIN="$(command -v tmux || echo /opt/homebrew/bin/tmux)"
WEZTERM_BIN="/Applications/WezTerm.app/Contents/MacOS/wezterm"

# If tmux server isn't running, there's nothing to attach to — bail.
if ! "$TMUX_BIN" list-sessions >/dev/null 2>&1; then
  exit 0
fi

wezterm_running() { /usr/bin/pgrep -x wezterm-gui >/dev/null 2>&1; }

if wezterm_running; then
  /usr/bin/osascript -e 'tell application id "com.github.wez.wezterm" to activate' >/dev/null 2>&1 || true

  clients="$("$TMUX_BIN" list-clients -F '#{client_tty}' 2>/dev/null || true)"
  if [ -n "$clients" ]; then
    while IFS= read -r tty; do
      [ -z "$tty" ] && continue
      "$TMUX_BIN" switch-client -c "$tty" -t "$session" >/dev/null 2>&1 || true
    done <<EOF
$clients
EOF
  else
    if [ -x "$WEZTERM_BIN" ]; then
      "$WEZTERM_BIN" cli spawn --new-window -- "$TMUX_BIN" attach -t "$session" >/dev/null 2>&1 || true
    fi
  fi
else
  /usr/bin/open -na WezTerm --args start -- "$TMUX_BIN" attach -t "$session" >/dev/null 2>&1 || true
fi

if [ -n "$window" ]; then
  "$TMUX_BIN" select-window -t "${session}:${window}" >/dev/null 2>&1 || true
fi

if [ -n "$pane_id" ]; then
  "$TMUX_BIN" select-pane -t "$pane_id" >/dev/null 2>&1 || true
fi
