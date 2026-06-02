#!/usr/bin/env bash
# PreToolUse hook for Edit|Write|NotebookEdit.
# If the working tree is on main/master/develop, create-and-checkout a
# claude/<file-slug>-<session-prefix> branch so LLM edits are always
# isolated and easy to discard.
#
# Reads hook JSON from stdin. Returns JSON to allow the tool call.
# Silent on non-applicable cases (not a git repo, already on a side branch,
# branch already created for this session).

set -u

input="$(cat)"

file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"

# Resolve repo root from the file being edited; fall back to cwd.
if [ -n "$file_path" ]; then
  repo_dir="$(dirname "$file_path")"
else
  repo_dir="$PWD"
fi

repo_root="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$repo_root" ]; then
  exit 0
fi

current_branch="$(git -C "$repo_root" symbolic-ref --short HEAD 2>/dev/null || true)"
case "$current_branch" in
  main|master|develop|trunk) ;;
  *) exit 0 ;;
esac

# Build a deterministic-per-session branch name.
slug=""
if [ -n "$file_path" ]; then
  base="$(basename "$file_path")"
  base="${base%.*}"
  slug="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
fi
[ -z "$slug" ] && slug="edits"
session_short="$(printf '%s' "$session_id" | tr -dc 'a-z0-9' | cut -c1-6)"
[ -z "$session_short" ] && session_short="$(date +%s | tail -c 7)"

branch="claude/${slug}-${session_short}"

# If a branch with this exact name already exists (e.g. earlier edit in same
# session), just check it out. Otherwise create it.
#
# If the checkout fails (almost always: dirty working tree on main with local
# changes that would be overwritten by the switch), we DENY the edit with a
# clear reason rather than silently letting it land on main. The user runs
# agents autonomously; a silent fall-through to main defeats the entire point
# of this hook.
if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
  checkout_err="$(git -C "$repo_root" checkout "$branch" 2>&1 >/dev/null)"
  checkout_rc=$?
else
  checkout_err="$(git -C "$repo_root" checkout -b "$branch" 2>&1 >/dev/null)"
  checkout_rc=$?
fi

if [ "$checkout_rc" -ne 0 ]; then
  reason="branch-guard: refusing to edit on $current_branch. Could not switch to $branch: $checkout_err. Commit, stash, or discard the conflicting changes (or switch to a side branch yourself) before letting Claude edit."
  jq -n --arg msg "branch-guard blocked edit: $current_branch has uncommitted changes blocking switch to $branch" \
        --arg reason "$reason" \
    '{systemMessage: $msg, hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
fi

jq -n --arg msg "Switched to $branch (was $current_branch) before edit" \
  '{systemMessage: $msg, hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow"}}'
