#!/usr/bin/env bash
# Notification hook: macOS popup with sound + tmux location + a rich, one-line
# description of what the agent is currently asking about.
#
# Reads hook JSON from stdin: {session_id, transcript_path, message, tool_name?}
#
# Strategy: parse the transcript JSONL to find (a) the most recent pending
# tool_use the agent emitted (the thing waiting on permission) and/or (b) the
# most recent assistant text (when the agent is asking a free-form question).
# Build a one-liner from that. Fall back to the framework's `message` if the
# transcript is missing or unparseable. Pure jq, no LLM call — keeps the hook
# fast and dependency-free.

set -u

input="$(cat)"

# ---- Pull fields from hook input ---------------------------------------------
fallback_msg="$(printf '%s' "$input" | jq -r '.message // "Claude needs your attention"')"
session_id_full="$(printf '%s' "$input" | jq -r '.session_id // empty')"
session_id="$(printf '%s' "$session_id_full" | cut -c1-6)"
transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty')"
hook_tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"

# ---- Build the rich description ---------------------------------------------
# Defaults to the framework message; we override if we successfully extract.
description="$fallback_msg"

build_description() {
  local path="$1"
  local hint_tool="$2"   # tool_name from hook input, may be empty
  [ -z "$path" ] && return 1
  [ ! -r "$path" ] && return 1

  # Each line in the transcript is ONE entry (assistant/user/system/etc.) and
  # for assistant entries, .message.content typically holds a SINGLE block
  # (thinking | text | tool_use). One agent turn spans several consecutive
  # entries. So "last assistant entry" is NOT the same as "last assistant
  # turn" — we have to walk multiple entries to reconstruct the right anchor.
  #
  # The rules we want:
  #   * Permission-required (hook input has tool_name): find the most recent
  #     unresolved tool_use entry — i.e., a tool_use whose id is not the
  #     subject of any subsequent tool_result. Prefer one matching hint_tool.
  #     If transcript hasn't flushed it, fall back to "Permission required:
  #     <tool>" so we never display stale data from a previous turn.
  #   * Idle / free-form question (no tool_name in hook input): find the
  #     trailing assistant text — the last assistant `text` block that
  #     appears AFTER the most recent user/tool_result entry. Anything
  #     before that boundary is from a prior turn and would be stale.

  # ---- Permission-required path -------------------------------------------
  if [ -n "$hint_tool" ]; then
    # Single jq pass: collect resolved tool_use ids, then find the LAST
    # tool_use entry whose id is unresolved AND whose name matches hint.
    # Output: tab-separated "name\tinput-json", or empty.
    local pending
    pending="$(jq -rn --arg hint "$hint_tool" '
      [inputs] as $all
      | ($all | map(select(.message.role == "user") | .message.content[]? | select(.type == "tool_result") | .tool_use_id) | unique) as $resolved
      | $all
        | map(select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | select(.name == $hint) | select(.id as $id | ($resolved | index($id)) | not))
        | last
        | if . == null then empty else "\(.name)\t\(.input | tojson)" end
    ' "$path" 2>/dev/null)"

    if [ -n "$pending" ]; then
      local pname pinput summary
      pname="${pending%%$'\t'*}"
      pinput="${pending#*$'\t'}"
      summary="$(summarize_tool "$pname" "$pinput")"
      if [ -n "$summary" ]; then
        finalize_summary "$summary"
        return 0
      fi
    fi

    # Transcript hasn't flushed the matching pending tool_use yet — use the
    # framework signal directly. NEVER silently surface a stale tool_use of
    # a different kind from earlier in the transcript.
    finalize_summary "Permission required: $hint_tool"
    return 0
  fi

  # ---- Idle / question path -----------------------------------------------
  # Find trailing assistant text: the last contiguous sequence of assistant
  # entries at the end of the transcript (after any user input). We walk
  # entries in order and reset our running text on any user entry; the
  # value at end-of-file is what we want.
  local trailing_text
  trailing_text="$(jq -rn '
    reduce inputs as $e (
      "";
      if ($e.message.role // "") == "user" then ""
      elif ($e.type == "assistant") then
        ([$e.message.content[]? | select(.type == "text") | .text] | join(" ")) as $t
        | if ($t // "") == "" then . else $t end
      else . end
    )
  ' "$path" 2>/dev/null)"

  if [ -n "$trailing_text" ] && [ "$trailing_text" != "null" ]; then
    finalize_summary "Asking: $trailing_text"
    return 0
  fi

  return 1
}

# Collapse whitespace, trim, cap to 120 chars, print.
finalize_summary() {
  local s="$1"
  s="$(printf '%s' "$s" | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//')"
  if [ "${#s}" -gt 120 ]; then
    s="${s:0:117}..."
  fi
  printf '%s' "$s"
}

summarize_tool() {
  local name="$1" input="$2"
  [ -z "$name" ] && return 1
  [ -z "$input" ] || [ "$input" = "empty" ] && { printf 'About to use: %s' "$name"; return 0; }

  case "$name" in
    Bash)
      local cmd
      cmd="$(printf '%s' "$input" | jq -r '.command // ""' 2>/dev/null)"
      if [ -n "$cmd" ]; then
        printf 'About to run: %s' "$cmd"
      else
        printf 'About to run a Bash command'
      fi
      ;;
    Edit|Write|NotebookEdit)
      local fp
      fp="$(printf '%s' "$input" | jq -r '.file_path // .notebook_path // ""' 2>/dev/null)"
      if [ -n "$fp" ]; then
        printf 'Wants to %s %s' "$(echo "$name" | tr '[:upper:]' '[:lower:]')" "$fp"
      else
        printf 'Wants to %s a file' "$(echo "$name" | tr '[:upper:]' '[:lower:]')"
      fi
      ;;
    Read)
      local fp
      fp="$(printf '%s' "$input" | jq -r '.file_path // ""' 2>/dev/null)"
      [ -n "$fp" ] && printf 'Wants to read %s' "$fp" || printf 'Wants to read a file'
      ;;
    Grep|Glob)
      local pat
      pat="$(printf '%s' "$input" | jq -r '.pattern // ""' 2>/dev/null)"
      [ -n "$pat" ] && printf '%s for: %s' "$name" "$pat" || printf 'About to use: %s' "$name"
      ;;
    WebFetch|WebSearch)
      local q
      q="$(printf '%s' "$input" | jq -r '.url // .query // ""' 2>/dev/null)"
      [ -n "$q" ] && printf '%s: %s' "$name" "$q" || printf 'About to use: %s' "$name"
      ;;
    Agent|Task)
      local desc
      desc="$(printf '%s' "$input" | jq -r '.description // ""' 2>/dev/null)"
      [ -n "$desc" ] && printf 'Spawning subagent: %s' "$desc" || printf 'Spawning a subagent'
      ;;
    *)
      # Generic fallback: show name and the first scalar input value if any.
      local first_val
      first_val="$(printf '%s' "$input" | jq -r '[.. | strings] | .[0] // ""' 2>/dev/null)"
      if [ -n "$first_val" ]; then
        printf 'About to use %s: %s' "$name" "$first_val"
      else
        printf 'About to use: %s' "$name"
      fi
      ;;
  esac
}

# Best-effort extraction; if anything fails, keep the fallback message.
if rich="$(build_description "$transcript_path" "$hook_tool_name" 2>/dev/null)" && [ -n "$rich" ]; then
  description="$rich"
fi

# ---- Tmux location -----------------------------------------------------------
# Capture session:window for the human-readable subtitle, plus the exact
# pane_id so the click handler can land on the right split.
location=""
pane_id=""
if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
  pane="${TMUX_PANE:-}"
  fmt='#S:#W'$'\t''#{pane_id}'
  if [ -n "$pane" ]; then
    loc_full="$(tmux display-message -p -t "$pane" "$fmt" 2>/dev/null || true)"
  else
    loc_full="$(tmux display-message -p "$fmt" 2>/dev/null || true)"
  fi
  location="${loc_full%%$'\t'*}"
  pane_id="${loc_full##*$'\t'}"
  # Guard against the format string being unsupported (output without a tab).
  [ "$location" = "$pane_id" ] && pane_id=""
fi

repo="$(basename "$PWD")"
title="Claude Code"
if [ -n "$location" ]; then
  subtitle="$location  ·  $repo"
else
  subtitle="$repo"
fi
[ -n "$session_id" ] && subtitle="$subtitle  ·  $session_id"

# ---- Build click action ------------------------------------------------------
# Clicking the notification jumps tmux to the session:window that fired it,
# and brings WezTerm to the front. Falls back gracefully when location is
# unknown (just activates WezTerm).
click_cmd=""
if [ -n "$location" ]; then
  tmux_session="${location%%:*}"
  tmux_window="${location#*:}"
  # Escape single quotes for safe re-execution by the shell
  # terminal-notifier spawns (which runs without a tmux calling-pane,
  # so we delegate to a helper that walks all attached clients).
  esc_session="${tmux_session//\'/\'\\\'\'}"
  esc_window="${tmux_window//\'/\'\\\'\'}"
  esc_pane="${pane_id//\'/\'\\\'\'}"
  click_cmd="$HOME/.claude/hooks/jump-to-tmux.sh '${esc_session}' '${esc_window}' '${esc_pane}'"
fi

# ---- Fire the notification ---------------------------------------------------
# Dry-run mode: dump what we WOULD show and exit. Useful for testing.
if [ "${CLAUDE_NOTIFY_DRY:-0}" = "1" ]; then
  printf 'title=%s\nsubtitle=%s\nmessage=%s\nclick=%s\n' "$title" "$subtitle" "$description" "$click_cmd"
  exit 0
fi

# Prefer terminal-notifier (clickable, separate notification settings, can run
# a shell command on click). Fall back to osascript if it's missing.
if command -v terminal-notifier >/dev/null 2>&1; then
  # `-group` so a new popup for the same session replaces the old one instead
  # of stacking — avoids piles of stale notifications from one busy agent.
  group_id="claude-code-${session_id_full:-default}"
  if [ -n "$click_cmd" ]; then
    # Note: -execute and -activate are mutually exclusive on click body.
    # We use -execute only and put WezTerm activation INSIDE the click command
    # so a single body-click both switches tmux and brings WezTerm to front.
    terminal-notifier \
      -title "$title" \
      -subtitle "$subtitle" \
      -message "$description" \
      -sound Glass \
      -group "$group_id" \
      -execute "$click_cmd" \
      >/dev/null 2>&1 || true
  else
    terminal-notifier \
      -title "$title" \
      -subtitle "$subtitle" \
      -message "$description" \
      -sound Glass \
      -group "$group_id" \
      -activate com.github.wez.wezterm \
      >/dev/null 2>&1 || true
  fi
else
  # Escape backslashes and double quotes for AppleScript.
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  osascript -e "display notification \"$(esc "$description")\" with title \"$(esc "$title")\" subtitle \"$(esc "$subtitle")\" sound name \"Glass\"" >/dev/null 2>&1 || true
fi
