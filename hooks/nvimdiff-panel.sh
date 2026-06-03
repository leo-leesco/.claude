#!/usr/bin/env bash
# Runs INSIDE the tmux review pane spawned by nvimdiff-edit.sh (so it has its
# own tty and can host nvim). Lets you accept / edit / reject a proposed change,
# writes "accept" or "reject" to <result>, and signals <chan> so the blocked
# hook resumes.
#
# Usage: nvimdiff-panel.sh <mode> <orig> <new> <result> <chan> <name>
#   mode   : auto   -> open the nvim diff straight away
#            prompt -> show [a]ccept / [e]dit / [r]eject first
#   orig   : original file (left, read-only)
#   new    : proposed file (right, editable) — final contents are read back
#   result : path to write the decision into
#   chan   : tmux wait-for channel to signal on exit
#   name   : display name of the file being changed

set -u

mode="$1"; orig="$2"; new="$3"; result="$4"; chan="$5"; name="$6"

finish() {
  printf '%s' "${1:-reject}" > "$result"
  tmux wait-for -S "$chan" 2>/dev/null
  exit 0
}
# Any unexpected exit (crash, pane killed) counts as a rejection so the edit
# never lands without an explicit accept.
trap 'finish reject' EXIT

# Open the side-by-side diff. `:cq` (quit-with-error) => reject; saving the
# proposed buffer and `:qa` => accept. The right buffer's contents on exit are
# what nvimdiff-edit.sh feeds back to Claude.
open_diff() {
  nvim -d "$orig" "$new" \
    -c 'wincmd l' \
    -c 'setlocal nomodified' \
    -c "file $name (proposed — edit me, :wqa to accept, :cq to reject)" \
    -c 'wincmd h | setlocal readonly nomodifiable | wincmd l'
  local rc=$?
  # nvim exits non-zero on :cq -> treat as reject; clean exit -> accept.
  if [ "$rc" -eq 0 ]; then finish accept; else finish reject; fi
}

if [ "$mode" = "auto" ]; then
  open_diff
fi

# prompt mode: small diff, offer a choice without forcing the editor open.
printf '\n  \033[1mClaude proposes a change to \033[36m%s\033[0m\n\n' "$name"
printf '    \033[32m[a]\033[0m accept   \033[33m[e]\033[0m edit in nvim   \033[31m[r]\033[0m reject\n\n  > '
# Read a single keypress from this pane's own tty.
read -rsn1 key < /dev/tty
case "$key" in
  a|A|"") finish accept ;;
  e|E)    open_diff ;;
  *)      finish reject ;;
esac
