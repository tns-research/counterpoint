#!/usr/bin/env bash
# counterpoint-plan.sh: the full-mode joint-planning front-end.
#
# In full mode both models plan independently against the same context, the
# divergence between the plans is the audit signal, and only the reconciled plan
# feeds production. counterpoint-run.sh hardens the critique half; this command
# hardens the planning half: it re-resolves the parity context from source (the
# command reads the files, not Opus), fetches Codex's plan read-only, and records
# BOTH plans as a per-turn artifact, so the front-end provably ran. The Stop hook
# requires this artifact in full mode.
#
# Config A keeps the reconciliation and role assignment as the live Opus's
# judgment. What this command makes un-fakeable is that Codex's independent plan
# was really obtained, and that Opus committed its own plan first: the Opus plan
# is passed in as a file written BEFORE Codex's plan is fetched, so the two plans
# are independent.
#
# Usage:
#   counterpoint-plan.sh \
#     --task "one-line description of the deliverable" \
#     --prompt PATH        (the original user request, verbatim) \
#     --opus-plan PATH     (Opus's plan, written to a file BEFORE this call) \
#     --resource PATH [--resource PATH ...]   (AGENTS.md / skill / files to inline) \
#     [--code] [-m MODEL]
#
# Prints Codex's plan and the run-dir path on stdout. Opus then reconciles the
# two plans (divergence = audit signal), writes the single agreed plan, assigns
# roles, and proceeds to production plus counterpoint-run.sh for the critique half.
set -euo pipefail

home="${COUNTERPOINT_HOME:-$HOME/.counterpoint}"
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
consult="$skill_dir/scripts/codex-consult.sh"
scaffold="$skill_dir/prompts/karpathy-scaffold.txt"

task=""
prompt=""
opus_plan=""
resources=()
is_code=0
model=""

die() { echo "counterpoint-plan.sh: $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --task) task="$2"; shift 2 ;;
    --prompt) prompt="$2"; shift 2 ;;
    --opus-plan) opus_plan="$2"; shift 2 ;;
    --resource) resources+=("$2"); shift 2 ;;
    --code) is_code=1; shift ;;
    -m) model="$2"; shift 2 ;;
    *) die "unknown arg '$1'" ;;
  esac
done

[ -n "$task" ] || die "--task is required"
[ -n "$prompt" ] || die "--prompt is required"
[ -f "$prompt" ] || die "prompt file not found: $prompt"
[ -n "$opus_plan" ] || die "--opus-plan is required (write Opus's plan to a file BEFORE this call, so the two plans stay independent)"
[ -f "$opus_plan" ] || die "opus-plan file not found: $opus_plan"
[ -x "$consult" ] || die "critic helper not executable: $consult"
[ -f "$scaffold" ] || die "scaffold not found: $scaffold"

# Tie this run to the current turn (the UserPromptSubmit hook writes the marker).
turn_id="manual"
[ -f "$home/current-turn" ] && turn_id="$(tr -d '[:space:]' < "$home/current-turn")"

runs_dir="$home/runs"
mkdir -p "$runs_dir"

ts="$(date +%Y%m%dT%H%M%S)-$$"
run="$runs_dir/$ts"
mkdir -p "$run"
printf '%s\n' "$turn_id" > "$run/turn_id"

# --- assemble the planning prompt from source (the command reads, not Opus) ---
planctx="$run/plan_context.txt"
{
  echo "<original_request>"
  cat "$prompt"
  echo
  echo "</original_request>"
  echo
  for r in "${resources[@]}"; do
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
  cat <<'INSTR'
INSTRUCTION:
You are one of two independent planners in a counterpoint loop. Follow the
Karpathy scaffold below before you plan or draft this pass:

INSTR
  cat "$scaffold"
  cat <<'INSTR'

Using ONLY the context above, produce a concise plan for this task: the steps in
order, the key decisions, the risks, and the edge cases. Do NOT implement or write
the deliverable yet; this is the planning pass only.
INSTR
} > "$planctx"

# --- fetch Codex's plan: one read-only Codex pass over the same context ---
plan_codex="$run/plan_codex.txt"
echo ">>> counterpoint: fetching Codex's plan (read-only) ..." >&2
consult_args=()
[ -n "$model" ] && consult_args=(-m "$model")
if "$consult" "${consult_args[@]}" < "$planctx" > "$plan_codex" 2>>"$run/plan_codex.stderr"; then
  codex_ok=1
else
  codex_ok=0
  echo "(codex plan call failed; see plan_codex.stderr)" >> "$plan_codex"
fi

# --- record Opus's plan (committed before this call, so the plans are independent) ---
cp "$opus_plan" "$run/plan_opus.txt"

# --- artifact: meta marks this as the planning phase. No log.txt is written, so
#     counterpoint-run.sh does not count this dir as a mini-loop round. ---
jstr() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'; }
{
  echo "{"
  echo "  \"ts\": \"$(jstr "$ts")\","
  echo "  \"turn_id\": \"$(jstr "$turn_id")\","
  echo "  \"mode\": \"full\","
  echo "  \"phase\": \"plan\","
  echo "  \"task\": \"$(jstr "$task")\","
  echo "  \"code\": $([ "$is_code" = 1 ] && echo true || echo false),"
  echo "  \"codex_ok\": $([ "$codex_ok" = 1 ] && echo true || echo false)"
  echo "}"
} > "$run/meta.json"

# --- report to the orchestrator on stdout ---
echo "=== counterpoint plan: $run ==="
echo
echo "--- Codex plan ---"
cat "$plan_codex"
echo
echo "(Opus plan recorded at $run/plan_opus.txt)"
echo
echo "Now reconcile: where the two plans agree is safe; where they diverge is the"
echo "audit signal. Settle each divergence on the ladder (03), write the single"
echo "agreed plan, assign roles, then produce and run counterpoint-run.sh."
echo
echo "run dir: $run"
