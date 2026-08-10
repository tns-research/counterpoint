#!/usr/bin/env bash
# counterpoint-plan.sh: the full-mode joint-planning front-end (v2 hardening,
# see eng/07-hardening-command-and-enforcement.md).
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
# is passed in as a file written BEFORE Codex's plan is visible, so the two plans
# are independent.
#
# Two ways to run it:
#
#   synchronous (default): Opus writes its plan, then calls this, then waits.
#     Simple, and the whole Codex plan latency (about a minute at the median,
#     much worse in the tail) is dead time.
#
#   split (--launch / --collect): Codex's plan is fetched in the background while
#     Opus drafts its own. Independence is preserved by construction rather than
#     by ordering: the planning prompt never contains Opus's plan, and Codex's
#     answer is held in a hidden pending file that only --collect reveals. So
#     there is nothing for Opus to read early. (Reading .plan_codex.pending by
#     hand before writing the Opus plan would break that, and is the one thing
#     not to do.) The run records both timestamps as evidence.
#
# Usage:
#   counterpoint-plan.sh \
#     --task "one-line description of the deliverable" \
#     --prompt PATH        (the original user request, verbatim) \
#     --opus-plan PATH     (Opus's plan, written to a file BEFORE this call) \
#     --resource PATH [--resource PATH ...]   (AGENTS.md / skill / files to inline) \
#     [--code] [-m MODEL] [-e EFFORT]
#
#   counterpoint-plan.sh --launch --task "..." --prompt PATH [--resource PATH ...] [--code]
#     -> prints the run dir; Codex plans in the background while Opus drafts.
#   counterpoint-plan.sh --collect --run RUNDIR --opus-plan PATH
#     -> waits for that background plan, records both, prints Codex's plan.
#
# Reasoning effort defaults to COUNTERPOINT_PLAN_EFFORT (default "high") applied
# as a cap: it lowers the configured effort for this cheaper phase and never
# raises it.
#
# Prints Codex's plan and the run-dir path on stdout. Opus then reconciles the
# two plans (divergence = audit signal), writes the single agreed plan, assigns
# roles, and proceeds to production plus counterpoint-run.sh for the critique half.
set -euo pipefail

home="${COUNTERPOINT_HOME:-$HOME/.counterpoint}"
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
consult="$skill_dir/scripts/codex-consult.sh"
scaffold="$skill_dir/prompts/karpathy-scaffold.txt"
# shellcheck source=./counterpoint-lib.sh
. "$skill_dir/scripts/counterpoint-lib.sh"

task=""
prompt=""
opus_plan=""
resources=()
is_code=0
model=""
effort="${COUNTERPOINT_PLAN_EFFORT:-high}"
phase="sync"
run_in=""

die() { echo "counterpoint-plan.sh: $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --task) task="$2"; shift 2 ;;
    --prompt) prompt="$2"; shift 2 ;;
    --opus-plan) opus_plan="$2"; shift 2 ;;
    --resource) resources+=("$2"); shift 2 ;;
    --code) is_code=1; shift ;;
    --launch) phase="launch"; shift ;;
    --collect) phase="collect"; shift ;;
    --run) run_in="$2"; shift 2 ;;
    -m) model="$2"; shift 2 ;;
    -e) effort="$2"; shift 2 ;;
    *) die "unknown arg '$1'" ;;
  esac
done

runs_dir="$home/runs"

# --- collect: wait for a --launch started earlier, then record both plans ------
if [ "$phase" = "collect" ]; then
  [ -n "$run_in" ] || die "--collect requires --run <rundir> (the path --launch printed)"
  run="${run_in%/}"
  [ -d "$run" ] || die "run dir not found: $run"
  [ -f "$run/.launch.pid" ] || die "not a launched plan run (no .launch.pid): $run"
  [ -n "$opus_plan" ] || die "--opus-plan is required (write Opus's plan to a file BEFORE collecting, so the two plans stay independent)"
  [ -f "$opus_plan" ] || die "opus-plan file not found: $opus_plan"

  pending="$run/.plan_codex.pending"
  plan_codex="$run/plan_codex.txt"
  launch_pid="$(tr -d '[:space:]' < "$run/.launch.pid" 2>/dev/null || echo "")"
  # The background job self-bounds via cp_codex_exec, so the clock is only the
  # backstop for a job that vanished without writing .launch.rc.
  max_wait=$(( ${COUNTERPOINT_CODEX_TIMEOUT:-600} * (1 + ${COUNTERPOINT_CODEX_RETRIES:-1}) + 120 ))
  waited=0
  while [ ! -f "$run/.launch.rc" ]; do
    # A killed background job (the terminal closed, the OS reclaimed it, an
    # errant kill) never writes .launch.rc, and waiting out the full backstop
    # then meant blocking the turn for twenty minutes on a process that no
    # longer exists. If the pid is gone and the rc file still is not there,
    # nothing is coming: fail now and say why.
    if [ -n "$launch_pid" ] && ! kill -0 "$launch_pid" 2>/dev/null; then
      sleep 1   # a last-moment writer beats the race
      [ -f "$run/.launch.rc" ] && break
      die "the background plan job (pid $launch_pid) is gone and wrote no result; re-launch. See $run/plan_codex.stderr"
    fi
    if [ "$waited" -ge "$max_wait" ]; then
      die "background plan did not finish within ${max_wait}s; see $run/plan_codex.stderr"
    fi
    sleep 2
    waited=$((waited + 2))
  done
  codex_rc="$(tr -d '[:space:]' < "$run/.launch.rc")"

  if [ "$codex_rc" = "0" ] && [ -s "$pending" ]; then
    mv "$pending" "$plan_codex"
    codex_ok=1
  else
    codex_ok=0
    : > "$plan_codex"
    echo "(codex plan call failed with exit $codex_rc; see plan_codex.stderr)" >> "$plan_codex"
  fi
  cp "$opus_plan" "$run/plan_opus.txt"

  launched_at="$(cat "$run/.launch.started" 2>/dev/null || echo 0)"
  {
    echo "{"
    echo "  \"ts\": \"$(cp_jstr "$(basename "$run")")\","
    echo "  \"turn_id\": \"$(cp_jstr "$(cat "$run/turn_id" 2>/dev/null || echo manual)")\","
    echo "  \"mode\": \"full\","
    echo "  \"phase\": \"plan\","
    echo "  \"split\": true,"
    echo "  \"launched_at\": \"$(cp_jstr "$launched_at")\","
    echo "  \"opus_plan_mtime\": \"$(cp_jstr "$(cp_mtime "$opus_plan")")\","
    echo "  \"task\": \"$(cp_jstr "$(cat "$run/task" 2>/dev/null || echo "")")\","
    echo "  \"codex_ok\": $([ "$codex_ok" = 1 ] && echo true || echo false)"
    echo "}"
  } > "$run/meta.json"
  [ "$codex_ok" = 1 ] && : > "$run/ok"
  rm -f "$run/.launch.pid" "$run/.launch.rc"

  echo "=== counterpoint plan (collected): $run ==="
  echo
  if [ "$codex_ok" != 1 ]; then
    echo "!!! CODEX PLAN FAILED: no usable plan came back (see plan_codex.stderr)."
    echo "!!! This phase is NOT recorded as done; re-launch before producing."
    echo
  fi
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
  exit 0
fi

# --- shared validation for sync and launch ------------------------------------
[ -n "$task" ] || die "--task is required"
[ -n "$prompt" ] || die "--prompt is required"
[ -f "$prompt" ] || die "prompt file not found: $prompt"
if [ "$phase" = "sync" ]; then
  [ -n "$opus_plan" ] || die "--opus-plan is required (write Opus's plan to a file BEFORE this call, so the two plans stay independent)"
  [ -f "$opus_plan" ] || die "opus-plan file not found: $opus_plan"
fi
[ -x "$consult" ] || die "critic helper not executable: $consult"
[ -f "$scaffold" ] || die "scaffold not found: $scaffold"

# Tie this run to the current turn (the UserPromptSubmit hook writes the marker).
turn_id="$(cp_turn_id "$home")"

mkdir -p "$runs_dir"
cp_gc_runs "$runs_dir"

ts="$(date +%Y%m%dT%H%M%S)-$$"
run="$runs_dir/$ts"
mkdir -p "$run"
printf '%s\n' "$turn_id" > "$run/turn_id"
printf '%s\n' "$task" > "$run/task"

# --- assemble the planning prompt from source (the command reads, not Opus) ---
planctx="$run/plan_context.txt"
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

consult_args=()
[ -n "$model" ] && consult_args+=(-m "$model")
[ -n "$effort" ] && consult_args+=(-e "$effort")

# --- launch: fetch Codex's plan in the background, return immediately ---------
if [ "$phase" = "launch" ]; then
  pending="$run/.plan_codex.pending"
  date +%s > "$run/.launch.started"
  (
    rc=0
    "$consult" ${consult_args+"${consult_args[@]}"} < "$planctx" > "$pending" 2>>"$run/plan_codex.stderr" || rc=$?
    printf '%s\n' "$rc" > "$run/.launch.rc"
  ) >>"$run/plan_codex.stderr" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  printf '%s\n' "$pid" > "$run/.launch.pid"

  echo "=== counterpoint plan (launched, pid $pid): $run ==="
  echo
  echo "Codex is planning in the background. Write YOUR plan now, to a file, then:"
  echo "  counterpoint-plan.sh --collect --run $run --opus-plan <opus-plan-file>"
  echo
  echo "Do not read $pending before then: the whole point of the split is that"
  echo "Codex's plan stays invisible until yours is committed."
  echo
  echo "run dir: $run"
  exit 0
fi

# --- synchronous: fetch Codex's plan, one read-only Codex pass ----------------
plan_codex="$run/plan_codex.txt"
echo ">>> counterpoint: fetching Codex's plan (read-only) ..." >&2
if "$consult" ${consult_args+"${consult_args[@]}"} < "$planctx" > "$plan_codex" 2>>"$run/plan_codex.stderr"; then
  codex_ok=1
else
  codex_ok=0
  echo "(codex plan call failed; see plan_codex.stderr)" >> "$plan_codex"
fi

# --- record Opus's plan (committed before this call, so the plans are independent) ---
cp "$opus_plan" "$run/plan_opus.txt"

# --- artifact: meta marks this as the planning phase. No log.txt is written, so
#     counterpoint-run.sh does not count this dir as a mini-loop round. ---
{
  echo "{"
  echo "  \"ts\": \"$(cp_jstr "$ts")\","
  echo "  \"turn_id\": \"$(cp_jstr "$turn_id")\","
  echo "  \"mode\": \"full\","
  echo "  \"phase\": \"plan\","
  echo "  \"split\": false,"
  echo "  \"task\": \"$(cp_jstr "$task")\","
  echo "  \"code\": $([ "$is_code" = 1 ] && echo true || echo false),"
  echo "  \"codex_ok\": $([ "$codex_ok" = 1 ] && echo true || echo false)"
  echo "}"
} > "$run/meta.json"
# The success marker: a failed or empty plan call must not read as a completed
# phase to the Stop hook.
[ "$codex_ok" = 1 ] && : > "$run/ok"

# --- report to the orchestrator on stdout ---
echo "=== counterpoint plan: $run ==="
echo
if [ "$codex_ok" != 1 ]; then
  echo "!!! CODEX PLAN FAILED: no usable plan came back (see plan_codex.stderr)."
  echo "!!! This phase is NOT recorded as done; re-run before producing."
  echo
fi
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
