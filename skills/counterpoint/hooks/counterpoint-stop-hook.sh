#!/usr/bin/env bash
# counterpoint-stop-hook.sh: the v2 enforcement backstop (see eng/07).
#
# Claude Code runs this when Opus tries to end the turn. The UserPromptSubmit
# hook injects the pipeline directive at the START; this Stop hook verifies at the
# END that the loop actually wrote its artifacts. If the turn was armed and the
# required artifacts do not exist for it, it blocks the stop and tells Opus to run
# the counterpoint command before finishing. That closes the one soft edge that
# remains: the trigger.
#
# Enforcement reads the LIVE toggle (~/.counterpoint/mode) as the single source of
# truth, re-read right here every time, never a frozen copy -- a frozen copy was
# the on-and-off incoherence, since it could still say full after the toggle went
# off. A manual /counterpoint is not separately enforced: the slash command loads
# the skill and runs the loop for that turn, and the toggle stays the one thing
# that arms this backstop.
#
# Contract: read the hook JSON payload on stdin. Exit 0 to allow the turn to end.
# Exit 2 to block it, with the reason on stderr (Claude Code feeds stderr back to
# Opus). The payload's stop_hook_active flag guards against an infinite block:
# once we have re-injected once, we step aside.
#
# Wired in settings.json under hooks.Stop. Dormant when the turn is not armed.
set -uo pipefail

home="${COUNTERPOINT_HOME:-$HOME/.counterpoint}"
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

payload="$(cat 2>/dev/null || true)"

# Already re-injected once this stop cycle: do not loop forever.
case "$payload" in
  *'"stop_hook_active"'*true*) exit 0 ;;
esac

# We need this turn's id first: a missing current-turn (the prompt hook did not
# fire) means we cannot attribute a run to this turn, so we do not block.
[ -f "$home/current-turn" ] || exit 0
turn_id="$(tr -d '[:space:]' < "$home/current-turn")"

# Enforcement comes from the toggle, re-read LIVE right now -- the single source
# of truth. This is the fix for the on-and-off incoherence: the old per-turn
# marker was a frozen copy that could still say full after the toggle went off.
mode="off"
[ -f "$home/mode" ] && mode="$(tr -d '[:space:]' < "$home/mode" 2>/dev/null || echo off)"
case "$mode" in
  small|full) : ;;
  *) exit 0 ;;   # dormant: toggle off, nothing to enforce
esac

# What got written for this turn? A critique run has log.txt; a full-mode plan
# phase (counterpoint-plan.sh) has plan_codex.txt; a full-mode plan review
# (counterpoint-review.sh) has plan_review.txt.
#
# Each phase must ALSO carry the `ok` marker and a non-empty artifact. The
# earlier version tested existence alone, and every phase script wrote its
# artifact whether or not the Codex call had succeeded, so a timed-out or empty
# critique satisfied the gate: the hook proved a file existed and nothing about
# whether the audit had happened. One recorded run came back with a zero-byte
# critique after nine minutes of a hung tool loop. `ok` is written only on a
# usable result.
ran=0
planned=0
reviewed=0
finalized=0
if [ -d "$home/runs" ]; then
  for d in "$home/runs"/*/; do
    [ -f "${d}turn_id" ] || continue
    [ "$(cat "${d}turn_id")" = "$turn_id" ] || continue
    [ -f "${d}log.txt" ] && [ -f "${d}ok" ] && [ -s "${d}critique.txt" ] && ran=1
    [ -f "${d}plan_codex.txt" ] && [ -f "${d}ok" ] && [ -s "${d}plan_codex.txt" ] && planned=1
    [ -f "${d}plan_review.txt" ] && [ -f "${d}ok" ] && [ -s "${d}plan_review.txt" ] && reviewed=1
    [ -s "${d}result.md" ] && finalized=1
  done
fi

# Both modes require the critique run (log.txt) AND the finalized deliverable
# (result.md), so the revision provably landed and is captured, not just the
# pre-revision draft (F5). full additionally requires the two plan phases -- the
# joint plan (F1) and the reconciled-plan review (F3) -- or a phase was skipped.
if [ "$mode" = "full" ]; then
  [ "$ran" = "1" ] && [ "$planned" = "1" ] && [ "$reviewed" = "1" ] && [ "$finalized" = "1" ] && exit 0
else
  [ "$ran" = "1" ] && [ "$finalized" = "1" ] && exit 0
fi

# Block: the loop did not fully run this turn. Name the missing phase.
{
  echo "counterpoint mode is ${mode} but the loop was not fully enforced this turn."
  echo "A phase whose Codex call timed out or came back empty does NOT count as run;"
  echo "check the matching *.stderr in the run dir before re-running it."
  if [ "$mode" = "full" ] && [ "$planned" != "1" ]; then
    echo "Missing the joint-planning front-end. Write Opus's plan to a file, then run:"
    echo "  ${skill_dir}/scripts/counterpoint-plan.sh --task \"<short>\" \\"
    echo "    --prompt <prompt-file> --opus-plan <opus-plan-file> --resource <each resource> [--code]"
    echo "Reconcile the two plans and assign roles before producing."
  fi
  if [ "$mode" = "full" ] && [ "$reviewed" != "1" ]; then
    echo "Missing the reconciled-plan review (F3). Write the agreed plan to a file, then run:"
    echo "  ${skill_dir}/scripts/counterpoint-review.sh --task \"<short>\" \\"
    echo "    --plan <agreed-plan-file> --prompt <prompt-file> \\"
    echo "    --reviewer <opus|codex> --producer <opus|codex> --resource <each resource> [--code]"
    echo "The reviewer is the non-producer. The producer then arbitrates the review before producing."
  fi
  if [ "$ran" != "1" ]; then
    echo "Missing the critique run. Save the producer's draft to a file, then run:"
    echo "  ${skill_dir}/scripts/counterpoint-run.sh --mode ${mode} --task \"<short>\" \\"
    echo "    --draft <draft-file> --prompt <prompt-file> --resource <each resource> [--code] [--verifier \"<cmd>\"]"
  fi
  if [ "$finalized" != "1" ]; then
    echo "Missing the finalized deliverable (result.md). After revising from the critique, run:"
    echo "  ${skill_dir}/scripts/counterpoint-finalize.sh --final <revised-file> \\"
    echo "    --caught \"<what the critique changed, or 'nothing, draft held'>\""
    echo "It writes result.md (the shipped, revised deliverable) and resolves the role log."
  fi
  echo "These write the run artifacts and let the turn end."
} >&2
exit 2
