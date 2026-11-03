#!/usr/bin/env bash
# UserPromptSubmit hook: stamp a turn for this session, arm it when the toggle
# (~/.counterpoint/mode) is small/full or the prompt starts with /counterpoint,
# and, for the toggle, tell Claude to run the loop. Silent when off.
set -uo pipefail
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$skill_dir/lib/core.sh"
home="${COUNTERPOINT_HOME:-$HOME/.counterpoint}"

payload="$(cat 2>/dev/null || true)"
prompt="$(printf '%s' "$payload" | cp_json_string prompt || true)"
sid="$(printf '%s' "$payload" | cp_json_string session_id | LC_ALL=C tr -cd 'A-Za-z0-9._-' | cut -c 1-64)"
[ -n "$sid" ] || sid="nosession"

mode="$(tr -d '[:space:]' < "$home/mode" 2>/dev/null || true)"
case "$mode" in small|full) ;; *) mode=off ;; esac

manual=""
case "$prompt" in
  "/counterpoint full"*) manual=full ;;
  "/counterpoint"*) manual=small ;;
esac
armed="${manual:-$mode}"

sdir="$home/sessions/$sid"
mkdir -p "$sdir" 2>/dev/null || exit 0
turn="$(printf '%s' "$sid" | cut -c 1-8)-$(date +%Y%m%d%H%M%S)-${RANDOM:-0}"
printf '%s\n' "$turn" > "$sdir/turn"
rm -f "$sdir/armed"
[ "$armed" = off ] && exit 0

mkdir -p "$home/turns/$turn/runs"
printf '%s\n' "$armed" > "$home/turns/$turn/mode"
date +%s > "$home/turns/$turn/started"
printf '%s %s\n' "$turn" "$armed" > "$sdir/armed"

# A typed /counterpoint already loads the skill; only the toggle needs a nudge.
[ -n "$manual" ] && exit 0
cat <<MSG
[counterpoint: mode=$armed, turn=$turn]
Run this turn through the counterpoint skill at $armed depth: read $skill_dir/SKILL.md and use $skill_dir/bin/counterpoint.
Finish with \`counterpoint done --final <file> --ledger <file>\`, or \`counterpoint skip "<reason>"\` if this turn has no deliverable (a question, a discussion). A Stop hook checks for one of them.
MSG
exit 0
