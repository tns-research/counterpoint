#!/usr/bin/env bash
# counterpoint-run.sh: the encapsulating command.
#
# This command owns the part of the loop that must not be faked or skipped: it
# re-resolves the parity context from source (the command reads the files, not
# Opus), runs the cross-model critique against that context, runs the hard
# verifier when one exists, and writes a per-turn run artifact under
# $COUNTERPOINT_HOME/runs/<ts>/. A Stop hook later checks that this artifact
# exists, so the loop provably ran.
#
# The critic is role-aware, and this is load-bearing: the critique must come from
# the model that did NOT produce, or the loop reviews itself and loses its point.
#   --critic codex : Opus produced, so Codex critiques (shelled read-only pass).
#   --critic opus  : Codex produced, so the live session Opus is the critic. The
#                    script does NOT call Codex here; it resolves the parity
#                    context into context.txt and the live Opus critiques it
#                    in-session. Calling Codex would be Codex-review-Codex.
#
# Opus calls this once per round with the producer's draft, then revises and
# finalizes from the returned critique + verdict. The capped mini-loop is bounded
# here: runs are tied to the current turn and refused past round 3.
#
# Usage:
#   counterpoint-run.sh \
#     --mode small|full \
#     --task "one-line description of the deliverable" \
#     --draft  PATH            (the producer's draft to audit) \
#     --prompt PATH            (the original user request, verbatim) \
#     --resource PATH [--resource PATH ...]   (AGENTS.md / skill / files to inline) \
#     [--plan PATH]            (full mode: the reconciled agreed plan, inlined so \
#                               the critic checks the draft against it) \
#     [--code]                 (also run `codex exec review`; mark task as code) \
#     [--verifier "CMD"]       (hard verifier; exit 0 = pass) \
#     [--producer opus|codex] [--critic opus|codex] [--finalizer opus|codex] \
#     [--plan-delta "one line"]  (full mode: what the two plans disagreed on)
#
# Prints the critique, the verifier verdict, the role-log block, and the run-dir
# path on stdout. Exit 0 on a completed audit (even if the verifier failed: a
# failing verifier is a result the orchestrator must act on, not a script error).
set -euo pipefail

home="${COUNTERPOINT_HOME:-$HOME/.counterpoint}"
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
consult="$skill_dir/scripts/codex-consult.sh"
scaffold="$skill_dir/prompts/karpathy-scaffold.txt"

mode=""
task=""
draft=""
prompt=""
plan=""
resources=()
is_code=0
verifier=""
producer="opus"
critic="codex"
critic_set=0
finalizer="opus"
plan_delta="n/a"
plan_score="n/a"

die() { echo "counterpoint-run.sh: $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --task) task="$2"; shift 2 ;;
    --draft) draft="$2"; shift 2 ;;
    --prompt) prompt="$2"; shift 2 ;;
    --plan) plan="$2"; shift 2 ;;
    --resource) resources+=("$2"); shift 2 ;;
    --code) is_code=1; shift ;;
    --verifier) verifier="$2"; shift 2 ;;
    --producer) producer="$2"; shift 2 ;;
    --critic) critic="$2"; critic_set=1; shift 2 ;;
    --finalizer) finalizer="$2"; shift 2 ;;
    --plan-delta) plan_delta="$2"; shift 2 ;;
    --plan-score) plan_score="$2"; shift 2 ;;
    *) die "unknown arg '$1'" ;;
  esac
done

# The critic is by rule the non-producer. If the caller set --producer but left
# --critic at its default, derive the critic from the producer so the loop cannot
# silently review itself (F2). An explicit --critic is still honored, then checked
# by the exclusivity guard below.
if [ "$critic_set" = 0 ]; then
  [ "$producer" = "opus" ] && critic="codex" || critic="opus"
fi

[ -n "$mode" ] || die "--mode is required (small|full)"
case "$mode" in small|full) : ;; *) die "--mode must be small or full" ;; esac
[ -n "$task" ] || die "--task is required"
[ -n "$draft" ] || die "--draft is required"
[ -f "$draft" ] || die "draft not found: $draft"
[ -n "$prompt" ] || die "--prompt is required"
[ -f "$prompt" ] || die "prompt file not found: $prompt"
case "$critic" in opus|codex) : ;; *) die "--critic must be opus or codex" ;; esac
case "$producer" in opus|codex) : ;; *) die "--producer must be opus or codex" ;; esac
case "$finalizer" in opus|codex) : ;; *) die "--finalizer must be opus or codex" ;; esac
# The critic must be the non-producer, or the loop reviews itself and loses its
# point (F2). This mirrors the reviewer!=producer guard in counterpoint-review.sh.
[ "$critic" != "$producer" ] || die "--critic and --producer must differ (the critic is the non-producer); got both '$producer'"
[ -z "$plan" ] || [ -f "$plan" ] || die "plan file not found: $plan"
# The Codex helper is only needed when Codex is the critic.
[ "$critic" != "codex" ] || [ -x "$consult" ] || die "critic helper not executable: $consult"
[ -f "$scaffold" ] || die "scaffold not found: $scaffold"

# Tie this run to the current turn (the UserPromptSubmit hook writes the marker).
turn_id="manual"
[ -f "$home/current-turn" ] && turn_id="$(tr -d '[:space:]' < "$home/current-turn")"

# Mini-loop round = how many runs already exist for this turn, plus one.
runs_dir="$home/runs"
mkdir -p "$runs_dir"
round=1
if [ "$turn_id" != "manual" ]; then
  prior=0
  for d in "$runs_dir"/*/; do
    # A "round" is a completed critique run (it has log.txt). Plan-phase dirs
    # written by counterpoint-plan.sh have no log.txt, so they never inflate the
    # mini-loop count.
    [ -f "${d}turn_id" ] && [ -f "${d}log.txt" ] || continue
    [ "$(cat "${d}turn_id")" = "$turn_id" ] && prior=$((prior + 1))
  done
  round=$((prior + 1))
fi
# Small mode is strictly single-pass and never loops: one critique per turn, then
# ship (SKILL.md step 6). Enforce it here so the bound cannot be narrated away --
# a second critique run in small mode is refused and pointed at full mode, where
# iteration lives. Full mode keeps the capped mini-loop at 3.
if [ "$mode" = "small" ] && [ "$round" -gt 1 ]; then
  die "small mode is single-pass and does not loop: a critique run already exists for turn $turn_id. Revise once from that critique and ship, or run full mode if you need iteration."
fi
if [ "$round" -gt 3 ]; then
  die "mini-loop cap reached (round $round > 3) for turn $turn_id; stop and ship with the failure surfaced"
fi

ts="$(date +%Y%m%dT%H%M%S)-$$"
run="$runs_dir/$ts"
mkdir -p "$run"
printf '%s\n' "$turn_id" > "$run/turn_id"

# --- assemble the parity context from source (the command reads, not Opus) ---
ctx="$run/context.txt"
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
  if [ -n "$plan" ]; then
    echo "<agreed_plan>"
    cat "$plan"
    echo
    echo "</agreed_plan>"
    echo
  fi
  echo "<producer_draft>"
  cat "$draft"
  echo
  echo "</producer_draft>"
  echo
  cat <<'INSTR'
INSTRUCTION:
You are the critic in a counterpoint loop. Apply the Karpathy scaffold below as a
standard for the work under review and a discipline for your own critique:

INSTR
  cat "$scaffold"
  cat <<'INSTR'

Using ONLY the context above, first produce a checklist verdict, one line per
stated constraint from the request and the resources, each marked PASS or FAIL
with a one-line reason. If an agreed plan is present above, also check whether the
draft follows it and flag any step it dropped or contradicted. Then list located
problems (name the exact sentence, claim, or function) with a concrete suggested
fix for each. Do not rewrite the draft; the producer will revise from your notes.
INSTR
} > "$ctx"

# --- critique: the cross-model pass over the parity context ---
# Whoever did NOT produce is the critic. Only shell to Codex when Codex is the
# critic; when Opus is the critic (Codex produced), the live session Opus reads
# context.txt and critiques in-session, so calling Codex here would be
# Codex-review-Codex and defeat the whole loop.
critique="$run/critique.txt"
if [ "$critic" = "codex" ]; then
  echo ">>> counterpoint: running Codex critique (read-only) ..." >&2
  if "$consult" < "$ctx" > "$critique" 2>>"$run/critique.stderr"; then
    critique_ok=1
  else
    critique_ok=0
    echo "(codex critique call failed; see critique.stderr)" >> "$critique"
  fi

  # --- code review: a second, model-diverse pass over the repo diff ---
  if [ "$is_code" = "1" ]; then
    echo ">>> counterpoint: running codex exec review ..." >&2
    {
      echo
      echo "=== codex exec review ==="
      codex exec review --skip-git-repo-check --color never 2>/dev/null || echo "(codex exec review unavailable)"
    } >> "$critique" || true
  fi
else
  # critic=opus: Codex produced this draft. The cross-model critic is the live
  # session Opus. The script resolves the parity context (context.txt above);
  # the live Opus critiques it in-session, then revises and finalizes. No Codex
  # call happens here by design.
  echo ">>> counterpoint: critic=opus; in-session critique of context.txt (no Codex call)" >&2
  critique_ok=1
  {
    echo "critic=opus (in-session)."
    echo
    echo "Codex produced the draft above, so the live session Opus is the critic."
    echo "Read the assembled parity context in context.txt and produce, in-session,"
    echo "the checklist verdict (one line per stated constraint, PASS/FAIL + reason)"
    echo "followed by located problems with a concrete fix each, then revise. No"
    echo "Codex critique is run here: that would be Codex reviewing its own output."
  } > "$critique"
fi

# --- hard verifier (code only): the top rung of the ladder ---
verifier_exit=""
verdict="n/a"
if [ -n "$verifier" ]; then
  echo ">>> counterpoint: running verifier: $verifier" >&2
  set +e
  bash -c "$verifier" > "$run/verifier.txt" 2>&1
  verifier_exit=$?
  set -e
  if [ "$verifier_exit" = "0" ]; then verdict="PASS"; else verdict="FAIL"; fi
fi

# Arbiter rung: a real hard verifier outranks the soft critique.
if [ -n "$verifier" ]; then arbiter_rung="hard-verifier"; else arbiter_rung="constraint-adherence"; fi

# --- artifact: copy the audited draft, write meta and the role log ---
# This is the PRE-revision draft, so it is saved as draft.md, not result.md.
# result.md is the shipped, revised deliverable and is written later by
# counterpoint-finalize.sh once the producer has revised from the critique (F5).
cp "$draft" "$run/draft.md"

jstr() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'; }
{
  echo "{"
  echo "  \"ts\": \"$(jstr "$ts")\","
  echo "  \"turn_id\": \"$(jstr "$turn_id")\","
  echo "  \"mode\": \"$(jstr "$mode")\","
  echo "  \"task\": \"$(jstr "$task")\","
  echo "  \"producer\": \"$(jstr "$producer")\","
  echo "  \"critic\": \"$(jstr "$critic")\","
  echo "  \"finalizer\": \"$(jstr "$finalizer")\","
  echo "  \"code\": $([ "$is_code" = 1 ] && echo true || echo false),"
  echo "  \"verifier\": \"$(jstr "$verifier")\","
  echo "  \"verifier_exit\": \"$(jstr "${verifier_exit:-}")\","
  echo "  \"verdict\": \"$(jstr "$verdict")\","
  echo "  \"arbiter_rung\": \"$(jstr "$arbiter_rung")\","
  echo "  \"plan_score\": \"$(jstr "$plan_score")\","
  echo "  \"round\": $round,"
  echo "  \"critique_ok\": $([ "$critique_ok" = 1 ] && echo true || echo false)"
  echo "}"
} > "$run/meta.json"

rounds_field="n/a"
[ -n "$verifier" ] && rounds_field="$round"
# The plan-review line only applies in full mode (small has no plan phase). The
# finalizer fills it from plan_review.txt via counterpoint-finalize.sh (F5).
plan_review_line="n/a"
[ "$mode" = "full" ] && plan_review_line="see plan_review.txt (finalizer fills this line)"
log="$run/log.txt"
{
  echo "counterpoint ($mode): producer=$producer critic=$critic finalizer=$finalizer"
  echo "plan score: $plan_score"
  echo "plan delta: $plan_delta"
  echo "plan review: $plan_review_line"
  echo "arbiter rung: $arbiter_rung"
  echo "mini-loop rounds: $rounds_field"
  echo "caught: see critique.txt (revision pending; finalizer fills this line)"
} > "$log"

# --- report to the orchestrator on stdout ---
echo "=== counterpoint run: $run ==="
echo
echo "--- critique ---"
cat "$critique"
echo
if [ -n "$verifier" ]; then
  echo "--- verifier verdict: $verdict (exit ${verifier_exit:-?}) ---"
  echo
fi
echo "--- role log ---"
cat "$log"
echo
echo "run dir: $run"
