#!/usr/bin/env bash
# counterpoint-review.sh: the full-mode F3 gate, the reconciled-plan review
# (v2 hardening, see eng/07-hardening-command-and-enforcement.md).
#
# Reconciliation (step F2, part 3) merges the two independent plans into one
# agreed plan. That merge is the live Opus's own work, so it can carry a step
# neither original plan had and that no one has checked. F3 closes that gap: the
# NON-producer (the reviewer) reads the reconciled plan before production. This
# command hardens F3 the same way counterpoint-plan.sh hardens F1: it re-resolves
# the parity context from source (the command reads the files, not Opus) and
# writes a per-turn plan-review artifact, so the review provably ran. The Stop
# hook requires this artifact in full mode.
#
# The one unified rule for what is hard vs soft:
#   a Codex (out-of-session) call is required  -> an artifact must prove it ran.
#   Opus acts in-session                       -> nothing to force; it IS the
#                                                 session and cannot fake presence.
# So this command is role-aware:
#   --reviewer codex : Opus produced, so Codex reviews the plan. This is a real
#                      out-of-session Codex call, run read-only. plan_review.txt
#                      holds Codex's review. [the DUR case]
#   --reviewer opus  : Codex produced, so the live session Opus is the reviewer.
#                      No Codex call is made; plan_review.txt records that the
#                      review was done in-session, and the roles, so the phase is
#                      provably addressed without spending a pointless Codex pass.
#                      [the SOFT case, still recorded so F3 cannot be half-skipped]
#
# Usage:
#   counterpoint-review.sh \
#     --task "one-line description of the deliverable" \
#     --plan   PATH            (the reconciled agreed plan, written to a file) \
#     --prompt PATH            (the original user request, verbatim) \
#     --reviewer opus|codex    (the NON-producer; who reviews the plan) \
#     --producer opus|codex    (who will produce; the other role) \
#     --resource PATH [--resource PATH ...]   (AGENTS.md / skill / files to inline) \
#     [--code] [-m MODEL]
#
# Prints the plan review and the run-dir path on stdout. The producer then
# arbitrates the review ("what do you think of this plan review?"), folds the
# kept points into the agreed plan, and only then produces.
set -euo pipefail

home="${COUNTERPOINT_HOME:-$HOME/.counterpoint}"
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
consult="$skill_dir/scripts/codex-consult.sh"
scaffold="$skill_dir/prompts/karpathy-scaffold.txt"
# shellcheck source=./counterpoint-lib.sh
. "$skill_dir/scripts/counterpoint-lib.sh"

task=""
plan=""
prompt=""
reviewer=""
producer=""
resources=()
is_code=0
model=""
effort="${COUNTERPOINT_REVIEW_EFFORT:-high}"

die() { echo "counterpoint-review.sh: $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --task) task="$2"; shift 2 ;;
    --plan) plan="$2"; shift 2 ;;
    --prompt) prompt="$2"; shift 2 ;;
    --reviewer) reviewer="$2"; shift 2 ;;
    --producer) producer="$2"; shift 2 ;;
    --resource) resources+=("$2"); shift 2 ;;
    --code) is_code=1; shift ;;
    -m) model="$2"; shift 2 ;;
    -e) effort="$2"; shift 2 ;;
    *) die "unknown arg '$1'" ;;
  esac
done

[ -n "$task" ] || die "--task is required"
[ -n "$plan" ] || die "--plan is required (write the reconciled agreed plan to a file first)"
[ -f "$plan" ] || die "plan file not found: $plan"
[ -n "$prompt" ] || die "--prompt is required"
[ -f "$prompt" ] || die "prompt file not found: $prompt"
[ -n "$reviewer" ] || die "--reviewer is required (opus|codex; the non-producer)"
case "$reviewer" in opus|codex) : ;; *) die "--reviewer must be opus or codex" ;; esac
[ -n "$producer" ] || die "--producer is required (opus|codex)"
case "$producer" in opus|codex) : ;; *) die "--producer must be opus or codex" ;; esac
[ "$reviewer" != "$producer" ] || die "--reviewer and --producer must differ (the reviewer is the non-producer)"
# The Codex helper is only needed when Codex is the reviewer.
[ "$reviewer" != "codex" ] || [ -x "$consult" ] || die "critic helper not executable: $consult"
[ -f "$scaffold" ] || die "scaffold not found: $scaffold"

# Tie this run to the current turn (the UserPromptSubmit hook writes the marker).
turn_id="$(cp_turn_id "$home")"

runs_dir="$home/runs"
mkdir -p "$runs_dir"
cp_gc_runs "$runs_dir"

ts="$(date +%Y%m%dT%H%M%S)-$$"
run="$runs_dir/$ts"
mkdir -p "$run"
printf '%s\n' "$turn_id" > "$run/turn_id"

plan_review="$run/plan_review.txt"

if [ "$reviewer" = "codex" ]; then
  # --- assemble the review context from source (the command reads, not Opus) ---
  revctx="$run/review_context.txt"
  {
    echo "<original_request>"
    cat "$prompt"
    echo
    echo "</original_request>"
    echo
    for r in ${resources+"${resources[@]}"}; do
      if [ -f "$r" ]; then
        echo "<resource path=\"$r\">"
        cat "$r"
        echo
        echo "</resource>"
        echo
      else
        echo "<resource path=\"$r\" missing=\"true\"></resource>"
        echo
      fi
    done
    echo "<reconciled_plan>"
    cat "$plan"
    echo
    echo "</reconciled_plan>"
    echo
    cat <<'INSTR'
INSTRUCTION:
You are the reviewer in a counterpoint loop. Apply the Karpathy scaffold below as
a standard for the work under review and a discipline for your own review:

INSTR
    cat "$scaffold"
    cat <<'INSTR'

The reconciled plan above is a merge of two independent plans; the merge may carry
a step neither original plan had. Using ONLY the context above, review the
reconciled plan and report located problems, one per line: which merged step is
unsupported, which constraint from the request or resources the merge dropped,
which invented option has no backing. For each, give a concrete fix. Do NOT
implement anything; this is the plan-review pass only. If the plan is sound, say
so plainly.
INSTR
  } > "$revctx"

  echo ">>> counterpoint: running Codex plan review (read-only) ..." >&2
  consult_args=()
  [ -n "$model" ] && consult_args+=(-m "$model")
  [ -n "$effort" ] && consult_args+=(-e "$effort")
  if "$consult" ${consult_args+"${consult_args[@]}"} < "$revctx" > "$plan_review" 2>>"$run/plan_review.stderr"; then
    review_ok=1
  else
    review_ok=0
    echo "(codex plan review call failed; see plan_review.stderr)" >> "$plan_review"
  fi
else
  # reviewer=opus: Codex produced, so the live session Opus is the reviewer. No
  # Codex call: Opus reads the reconciled plan in-session and reports located
  # problems there. This marker records that F3 was addressed and by whom, so the
  # Stop hook can confirm the phase ran without forcing a pointless Codex pass.
  echo ">>> counterpoint: reviewer=opus; in-session plan review (no Codex call)" >&2
  review_ok=1
  {
    echo "reviewer=opus (in-session)."
    echo
    echo "Codex is the producer this turn, so the live session Opus is the plan"
    echo "reviewer. Read the reconciled agreed plan and report, in-session, the"
    echo "located problems (unsupported merged step, dropped constraint, invented"
    echo "option with no backing) with a concrete fix each. No Codex call is run"
    echo "here: Codex is producing, so a Codex plan review would review its own"
    echo "upcoming work. Codex (the producer) then arbitrates this review."
  } > "$plan_review"
fi

# --- artifact: meta marks this as the review phase. No log.txt is written, so
#     counterpoint-run.sh does not count this dir as a mini-loop round. ---
jstr() { cp_jstr "$1"; }
{
  echo "{"
  echo "  \"ts\": \"$(jstr "$ts")\","
  echo "  \"turn_id\": \"$(jstr "$turn_id")\","
  echo "  \"mode\": \"full\","
  echo "  \"phase\": \"review\","
  echo "  \"task\": \"$(jstr "$task")\","
  echo "  \"producer\": \"$(jstr "$producer")\","
  echo "  \"reviewer\": \"$(jstr "$reviewer")\","
  echo "  \"code\": $([ "$is_code" = 1 ] && echo true || echo false),"
  echo "  \"review_ok\": $([ "$review_ok" = 1 ] && echo true || echo false)"
  echo "}"
} > "$run/meta.json"
# The success marker: a failed or empty Codex review must not read to the Stop
# hook as a completed F3 phase.
[ "$review_ok" = 1 ] && : > "$run/ok"

# --- report to the orchestrator on stdout ---
echo "=== counterpoint plan review: $run ==="
echo
if [ "$review_ok" != 1 ]; then
  echo "!!! CODEX PLAN REVIEW FAILED: no usable review came back (see plan_review.stderr)."
  echo "!!! This phase is NOT recorded as done; re-run before producing."
  echo
fi
echo "--- plan review (reviewer=$reviewer) ---"
cat "$plan_review"
echo
echo "Now the producer ($producer) arbitrates this review: for each point, keep or"
echo "reject with a reason, fold the kept points into the agreed plan, then produce."
echo
echo "run dir: $run"
