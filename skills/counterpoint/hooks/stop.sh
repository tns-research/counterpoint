#!/usr/bin/env bash
# Stop hook: an armed turn must end with `counterpoint done` or `counterpoint skip`.
# It refuses the first stop that has neither (exit 2 sends the reason back to
# Claude). A second stop is allowed and recorded in escapes.log, so the hook can
# never trap a session.
set -uo pipefail
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$skill_dir/lib/core.sh"
home="${COUNTERPOINT_HOME:-$HOME/.counterpoint}"

payload="$(cat 2>/dev/null || true)"
sid="$(printf '%s' "$payload" | cp_json_string session_id | LC_ALL=C tr -cd 'A-Za-z0-9._-' | cut -c 1-64)"
[ -n "$sid" ] || sid="nosession"
armed_file="$home/sessions/$sid/armed"
[ -f "$armed_file" ] || exit 0
read -r turn mode < "$armed_file" || exit 0
tdir="$home/turns/$turn"
[ -f "$tdir/done" ] && exit 0

running=""
for r in "$tdir"/runs/*; do
  [ -f "$r/status" ] && [ "$(cat "$r/status")" = running ] && running="$running $(basename "$r")"
done

if [ -f "$tdir/refused" ]; then
  printf '%s turn=%s mode=%s session=%s running=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$turn" "$mode" "$sid" "${running:-none}" >> "$home/escapes.log"
  exit 0
fi
: > "$tdir/refused"
{
  echo "counterpoint ($mode) is armed for this turn and it has not been closed."
  [ -n "$running" ] && echo "Codex is still running:$running. Collect it with: $skill_dir/bin/counterpoint wait"
  echo "Finish the loop and close it with: $skill_dir/bin/counterpoint done --final <file> --ledger <file>"
  echo "If this turn has no deliverable, close it with: $skill_dir/bin/counterpoint skip \"<reason>\""
} >&2
exit 2
