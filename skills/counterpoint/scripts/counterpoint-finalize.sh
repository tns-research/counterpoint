#!/usr/bin/env bash
# counterpoint-finalize.sh: the deliver-phase artifact writer (v2 hardening, see
# eng/07-hardening-command-and-enforcement.md, F5).
#
# counterpoint-run.sh audits the PRE-revision draft: it saves that draft as
# draft.md and leaves result.md unwritten, with the role log carrying placeholder
# "caught:" and (in full mode) "plan review:" lines. Those placeholders prove the
# critique phase ran but not that the revision landed. This command closes that
# gap: after the producer revises from the critique, the finalizer runs this to
# write result.md (the shipped, revised deliverable) and to replace the two
# placeholder log lines with the resolved outcome. The Stop hook requires
# result.md, so the deliver phase provably ran and the revised content is captured
# in the enforced artifact set, not just the draft.
#
# Usage:
#   counterpoint-finalize.sh \
#     --final PATH             (the shipped, revised deliverable) \
#     --caught "one line"      (what the critique changed, or "nothing, draft held") \
#     [--run PATH]             (the run dir from counterpoint-run.sh; default: the
#                               latest critique run for the current turn) \
#     [--plan-review "one line"]  (full mode: what the critic flagged in the
#                                  reconciled plan and what the producer kept)
#
# Prints the finalized result path and the updated role log on stdout.
set -euo pipefail

home="${COUNTERPOINT_HOME:-$HOME/.counterpoint}"

final=""
run=""
caught=""
plan_review=""

die() { echo "counterpoint-finalize.sh: $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --final) final="$2"; shift 2 ;;
    --run) run="$2"; shift 2 ;;
    --caught) caught="$2"; shift 2 ;;
    --plan-review) plan_review="$2"; shift 2 ;;
    *) die "unknown arg '$1'" ;;
  esac
done

[ -n "$final" ] || die "--final is required (the shipped, revised deliverable)"
[ -f "$final" ] || die "final deliverable not found: $final"
[ -n "$caught" ] || die "--caught is required (one line: what the critique changed, or \"nothing, draft held\")"

# Resolve the run dir. If not given, find the latest critique run (has log.txt)
# tied to the current turn, so the finalizer does not have to track the timestamp.
if [ -z "$run" ]; then
  [ -f "$home/current-turn" ] || die "no --run given and no current-turn marker to resolve it from"
  turn_id="$(tr -d '[:space:]' < "$home/current-turn")"
  latest=""
  if [ -d "$home/runs" ]; then
    for d in "$home/runs"/*/; do
      [ -f "${d}turn_id" ] && [ -f "${d}log.txt" ] || continue
      [ "$(cat "${d}turn_id")" = "$turn_id" ] || continue
      latest="$d"
    done
  fi
  [ -n "$latest" ] || die "no critique run found for the current turn; run counterpoint-run.sh first"
  run="${latest%/}"
fi

[ -d "$run" ] || die "run dir not found: $run"
[ -f "$run/log.txt" ] || die "run dir has no log.txt (not a critique run): $run"

# --- write the shipped, revised deliverable ---
cp "$final" "$run/result.md"

# --- rewrite the resolved log lines in place (caught, and plan review in full) ---
log="$run/log.txt"
tmp="$run/log.txt.tmp"
: > "$tmp"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "caught:"*)
      printf 'caught: %s\n' "$caught" >> "$tmp" ;;
    "plan review:"*)
      if [ -n "$plan_review" ]; then
        printf 'plan review: %s\n' "$plan_review" >> "$tmp"
      else
        printf '%s\n' "$line" >> "$tmp"
      fi ;;
    *)
      printf '%s\n' "$line" >> "$tmp" ;;
  esac
done < "$log"
mv "$tmp" "$log"

# --- report to the orchestrator on stdout ---
echo "=== counterpoint finalize: $run ==="
echo
echo "result.md written from: $final"
echo
echo "--- role log ---"
cat "$log"
echo
echo "run dir: $run"
