#!/usr/bin/env bash
# counterpoint-mode.sh: read or set the always-on toggle.
#
# The toggle is a single word stored in ~/.counterpoint/mode: off | small | full.
# The UserPromptSubmit hook reads it every turn. "off" (or no file) means the
# loop is dormant and plain single-model Claude Code runs.
#
# Usage:
#   counterpoint-mode.sh                 # print current mode
#   counterpoint-mode.sh status          # same, verbose
#   counterpoint-mode.sh off|small|full  # set mode
set -euo pipefail

state_dir="${COUNTERPOINT_HOME:-$HOME/.counterpoint}"
state_file="$state_dir/mode"

read_mode() {
  if [ -f "$state_file" ]; then
    tr -d '[:space:]' < "$state_file"
  else
    echo "off"
  fi
}

cmd="${1:-get}"
case "$cmd" in
  get)
    read_mode
    ;;
  status)
    m="$(read_mode)"
    echo "counterpoint mode: $m"
    case "$m" in
      off) echo "the loop is dormant; plain single-model Claude Code runs." ;;
      small) echo "every turn runs cross-criticism (produce, critique, revise, deliver)." ;;
      full) echo "every turn adds the joint planning front-end before production." ;;
      *) echo "unrecognized mode value; treat as off." ;;
    esac
    ;;
  off|small|full)
    mkdir -p "$state_dir"
    printf '%s\n' "$cmd" > "$state_file"
    echo "counterpoint mode set to: $cmd"
    ;;
  *)
    echo "counterpoint-mode.sh: unknown command '$cmd' (use: get | status | off | small | full)" >&2
    exit 2
    ;;
esac
