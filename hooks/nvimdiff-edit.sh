#!/usr/bin/env bash
# PreToolUse hook for Edit|Write (standalone *terminal* Claude only).
#
# Opens the proposed change in an nvim diff in a side tmux pane so you can
# review and HAND-EDIT it before it lands:
#   - diffs >= $CLAUDE_NVIMDIFF_THRESHOLD changed lines (default 40) auto-open
#     the nvim diff
#   - smaller diffs first show a one-key prompt: [a]ccept / [e]dit / [r]eject
# Whatever you leave in the right-hand (proposed) buffer is what gets applied,
# via `permissionDecision: allow` + `updatedInput` (replaces Claude's own
# confirmation prompt). :cq in nvim, or 'r' at the prompt, rejects the edit.
#
# This hook deliberately does NOTHING (exit 0, normal Claude flow) when:
#   - not an interactive CLI session (e.g. `claude -p` / SDK)        -> would hang
#   - Claude is hosted inside nvim via claudecode.nvim (SSE_PORT set) -> the
#     plugin already shows a far better in-editor diff
#   - not inside tmux, or no tmux client is attached                 -> no UI
#   - nvim/tmux missing, or on a protected branch with a dirty tree
#     (so branch-guard's deny wins without wasting your editing time)
#   - disabled via CLAUDE_NVIMDIFF_DISABLE=1
#
# Reads hook JSON on stdin; emits decision JSON on stdout. Any unexpected
# failure falls through to exit 0 so a buggy hook can never block your edits.

set -u

input="$(cat)"

# --- read the event -------------------------------------------------------
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
[ -z "$fp" ] && exit 0
case "$tool_name" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

# --- gates: when to stay out of the way -----------------------------------
[ "${CLAUDE_NVIMDIFF_DISABLE:-0}" = "1" ] && exit 0
# Interactive terminal Claude only. Print/SDK mode reports "sdk-cli" and has
# nobody to drive the pane, so opening nvim would hang the run.
[ "${CLAUDE_CODE_ENTRYPOINT:-}" = "cli" ] || exit 0
# Hosted inside nvim (claudecode.nvim) -> let the plugin's diff handle it.
[ -n "${CLAUDE_CODE_SSE_PORT:-}" ] && exit 0
# Need tmux with an attached client to show the pane.
[ -n "${TMUX:-}" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0
command -v nvim >/dev/null 2>&1 || exit 0
[ -n "$(tmux list-clients 2>/dev/null)" ] || exit 0

# Coordinate with branch-guard.sh: if we're on a protected branch with a dirty
# tree, branch-guard may DENY this edit. Deny wins regardless, so bail now
# rather than make you edit in nvim only to have it thrown away.
repo_root="$(git -C "$(dirname "$fp")" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$repo_root" ]; then
  cur_branch="$(git -C "$repo_root" symbolic-ref --short HEAD 2>/dev/null || true)"
  case "$cur_branch" in
    main|master|develop|trunk)
      [ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null)" ] && exit 0
      ;;
  esac
fi

# --- build original + proposed views --------------------------------------
tmpd="$(mktemp -d "${CLAUDE_CODE_TMPDIR:-/tmp}/ccnvimdiff.XXXXXX")" || exit 0
trap 'rm -rf "$tmpd"' EXIT
base="$(basename "$fp")"
orig="$tmpd/ORIGINAL_$base"   # left pane, read-only
new="$tmpd/$base"             # right pane, you edit this; extension kept for ft

# Original = current file contents (empty for a brand-new file).
if [ -f "$fp" ]; then cp "$fp" "$orig"; else : > "$orig"; fi

if [ "$tool_name" = "Write" ]; then
  # Proposed = the content Claude wants to write, byte-exact (jq -j: no newline).
  printf '%s' "$input" | jq -j '.tool_input.content // ""' > "$new"
else
  # Edit: reproduce Claude's old_string -> new_string replacement on the file.
  printf '%s' "$input" | jq -j '.tool_input.old_string // ""' > "$tmpd/old"
  printf '%s' "$input" | jq -j '.tool_input.new_string // ""' > "$tmpd/newstr"
  replace_all="$(printf '%s' "$input" | jq -r '.tool_input.replace_all // false')"
  ORIGF="$orig" OLDF="$tmpd/old" NEWF="$tmpd/newstr" OUTF="$new" RALL="$replace_all" \
    python3 -c '
import os
data = open(os.environ["ORIGF"]).read()
old  = open(os.environ["OLDF"]).read()
new  = open(os.environ["NEWF"]).read()
res  = data.replace(old, new) if os.environ.get("RALL") == "true" else data.replace(old, new, 1)
open(os.environ["OUTF"], "w").write(res)
' || exit 0
fi

# If the proposed result is identical to the current file, there is nothing to
# review (e.g. Edit old_string not found). Defer to Claude's normal handling.
cmp -s "$orig" "$new" && exit 0

# --- decide auto-open vs prompt -------------------------------------------
threshold="${CLAUDE_NVIMDIFF_THRESHOLD:-40}"
changed="$(diff "$orig" "$new" 2>/dev/null | grep -cE '^[<>]' || true)"
if [ "${changed:-0}" -ge "$threshold" ]; then
  mode="auto"
else
  mode="prompt"
fi

# --- spawn the review pane and block until it resolves --------------------
result="$tmpd/result"
sess_short="$(printf '%s' "$session_id" | tr -dc 'a-z0-9' | cut -c1-8)"
chan="ccnvd_${sess_short}_$$"
panel="$HOME/.claude/hooks/nvimdiff-panel.sh"
[ -x "$panel" ] || exit 0

cmd="$(printf '%q %q %q %q %q %q %q' \
  "$panel" "$mode" "$orig" "$new" "$result" "$chan" "$base")"

target="${TMUX_PANE:-}"
if [ -n "$target" ]; then
  pane="$(tmux split-window -h -t "$target" -l 55% -P -F '#{pane_id}' "$cmd" 2>/dev/null)"
else
  pane="$(tmux split-window -h -l 55% -P -F '#{pane_id}' "$cmd" 2>/dev/null)"
fi
# If we couldn't open the pane, fall back to Claude's normal prompt.
[ -z "$pane" ] && exit 0
tmux select-pane -t "$pane" 2>/dev/null || true

# Block until the panel signals (default per-hook timeout is 600s).
tmux wait-for "$chan" 2>/dev/null

status="$(cat "$result" 2>/dev/null || echo reject)"

# A no-op result (you reverted every change in nvim) is a rejection.
if [ "$status" = "accept" ] && ! cmp -s "$orig" "$new"; then
  if [ "$tool_name" = "Write" ]; then
    jq -n --arg fp "$fp" --rawfile c "$new" \
      '{systemMessage: "nvimdiff: applied your reviewed version",
        hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow",
          permissionDecisionReason: "user reviewed/edited the change in nvim",
          updatedInput: {file_path: $fp, content: $c}}}'
  else
    # Whole-file swap: old_string = exact current file, new_string = your buffer.
    jq -n --arg fp "$fp" --rawfile o "$orig" --rawfile n "$new" \
      '{systemMessage: "nvimdiff: applied your reviewed version",
        hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow",
          permissionDecisionReason: "user reviewed/edited the change in nvim",
          updatedInput: {file_path: $fp, old_string: $o, new_string: $n, replace_all: false}}}'
  fi
else
  jq -n '{systemMessage: "nvimdiff: edit rejected",
          hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
            permissionDecisionReason: "user rejected the change in the nvim review pane"}}'
fi
