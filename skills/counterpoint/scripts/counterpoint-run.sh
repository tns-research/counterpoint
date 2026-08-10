#!/usr/bin/env bash
# counterpoint-run.sh: the encapsulating command (v2 hardening, see
# eng/07-hardening-command-and-enforcement.md).
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
#
# Every Codex call here is bounded by COUNTERPOINT_CODEX_TIMEOUT (default 600s)
# and retried once on a transient failure, and an empty final message counts as a
# failure. The hard verifier is bounded too, by COUNTERPOINT_VERIFIER_TIMEOUT
# (default 900s), so a hung test suite fails the turn instead of freezing it.
# A run that did not get a usable critique writes no `ok` marker: it is
# not counted as a mini-loop round, the Stop hook keeps refusing to end the turn,
# and stdout says so plainly. On code tasks `codex exec review` runs in parallel
# with the critique instead of after it.
set -euo pipefail

home="${COUNTERPOINT_HOME:-$HOME/.counterpoint}"
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
consult="$skill_dir/scripts/codex-consult.sh"
scaffold="$skill_dir/prompts/karpathy-scaffold.txt"
# shellcheck source=./counterpoint-lib.sh
. "$skill_dir/scripts/counterpoint-lib.sh"

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
turn_id="$(cp_turn_id "$home")"

runs_dir="$home/runs"
mkdir -p "$runs_dir"
cp_gc_runs "$runs_dir"

# Mini-loop round = how many SUCCESSFUL critique runs already exist for this
# turn, plus one. A round is a completed critique run: it has log.txt (plan-phase
# dirs have none, so they never inflate the count) and the `ok` marker. Counting
# only successful runs matters: a Codex call that timed out or came back empty
# must not consume the single pass small mode is allowed, or a transient failure
# would lock the turn out of its own retry while the Stop hook still demands a
# critique.
prior="$(cp_count_runs "$runs_dir" "$turn_id" log.txt)"
round=$((prior + 1))
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
  # --- code review: a second, model-diverse pass over the repo diff ---
  # Started FIRST and in the background: it is independent of the critique over
  # the parity context, so running the two back to back was serializing one to
  # three minutes for nothing. Both are collected before the artifact is written.
  #
  # It also gets the same isolation as every other Codex call here. It used to be
  # a bare `codex exec review` with the user config live, which is exactly the
  # configuration that let an MCP web-search server hang the turn under a
  # networkless sandbox, with stderr discarded so the failure was invisible.
  review_pid=""
  review_out="$run/code_review.txt"
  if [ "$is_code" = "1" ]; then
    echo ">>> counterpoint: running codex exec review (parallel) ..." >&2
    cfg_model="$(cp_cfg_value model)"
    cfg_reasoning="$(cp_cfg_value model_reasoning_effort)"
    review_effort="$(cp_effort_min "${COUNTERPOINT_CRITIQUE_EFFORT:-$cfg_reasoning}" "$cfg_reasoning")"
    review_bypass="$(cp_sandbox_bypass)"
    cp_sandbox_announce "codex exec review" "$review_bypass"
    # If the sandbox is known-broken and the bypass was explicitly refused, this
    # pass cannot read the diff. It would still exit 0 with a courteous "no
    # findings", so it is failed here rather than appended as a verdict.
    review_blind=0
    if [ "$review_bypass" = "0" ] && ! cp_sandbox_usable; then review_blind=1; fi
    (
      # Flags verified against codex-cli 0.144: `review` is its own subcommand
      # with its own parser. It rejects --color ("unexpected argument"), which
      # the previous call site passed, so this pass had been failing outright
      # and the failure was swallowed by `2>/dev/null || echo "(unavailable)"`.
      # It also requires an explicit target; --uncommitted is the producer's
      # working diff, which is what the critique is about.
      rargs=(exec review --uncommitted --skip-git-repo-check --ignore-user-config -o "$review_out")
      # Same gVisor caveat as the producer write path: `review` shells out to git
      # to read the diff, and Codex's bubblewrap sandbox cannot start there, so
      # the pass comes back saying it "could not inspect the repository diff"
      # while still exiting 0. With the outer sandbox providing the isolation,
      # the bypass is what makes this pass actually see the change.
      [ "$review_bypass" = "1" ] && rargs+=(--dangerously-bypass-approvals-and-sandbox)
      [ -n "$cfg_model" ] && rargs+=(-c "model=\"$cfg_model\"")
      [ -n "$review_effort" ] && rargs+=(-c "model_reasoning_effort=\"$review_effort\"")
      cp_codex_exec "$review_out" -- "${rargs[@]}"
    ) >>"$run/code_review.stderr" 2>&1 &
    review_pid=$!
  fi

  echo ">>> counterpoint: running Codex critique (read-only) ..." >&2
  critique_effort_args=()
  [ -n "${COUNTERPOINT_CRITIQUE_EFFORT:-}" ] && critique_effort_args=(-e "$COUNTERPOINT_CRITIQUE_EFFORT")
  if "$consult" ${critique_effort_args+"${critique_effort_args[@]}"} < "$ctx" > "$critique" 2>>"$run/critique.stderr"; then
    critique_ok=1
  else
    critique_ok=0
    echo "(codex critique call failed; see critique.stderr)" >> "$critique"
  fi

  if [ -n "$review_pid" ]; then
    review_rc=0
    wait "$review_pid" || review_rc=$?
    {
      echo
      echo "=== codex exec review ==="
      if [ "$review_blind" = "1" ]; then
        echo "(codex exec review could not read the diff: Codex's sandbox cannot start on this host and COUNTERPOINT_CODEX_BYPASS_SANDBOX=0 refuses the bypass. Its verdict is discarded rather than reported as a clean review.)"
      elif [ "$review_rc" = 0 ] && [ -s "$review_out" ]; then
        cat "$review_out"
      else
        echo "(codex exec review failed with exit $review_rc; see code_review.stderr)"
      fi
    } >> "$critique"
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
  # Bounded like every Codex call, and for the same reason: the verifier is an
  # arbitrary command the orchestrator supplies, so a hung test suite or a
  # process waiting on input froze the turn with no way out. A verifier that
  # times out is a FAIL the orchestrator must act on, not a hang.
  vtmo="${COUNTERPOINT_VERIFIER_TIMEOUT:-900}"
  set +e
  cp_bound "$vtmo" -- bash -c "$verifier" > "$run/verifier.txt" 2>&1
  verifier_exit=$?
  set -e
  if [ "$verifier_exit" = "0" ]; then
    verdict="PASS"
  else
    verdict="FAIL"
    if [ "$verifier_exit" = "124" ]; then
      echo "(verifier exceeded the ${vtmo}s bound and was killed)" >> "$run/verifier.txt"
    fi
  fi
fi

# Arbiter rung: a real hard verifier outranks the soft critique.
if [ -n "$verifier" ]; then arbiter_rung="hard-verifier"; else arbiter_rung="constraint-adherence"; fi

# --- artifact: copy the audited draft, write meta and the role log ---
# This is the PRE-revision draft, so it is saved as draft.md, not result.md.
# result.md is the shipped, revised deliverable and is written later by
# counterpoint-finalize.sh once the producer has revised from the critique (F5).
cp "$draft" "$run/draft.md"

# The success marker. The Stop hook and the round counter both key off this
# rather than off the mere existence of log.txt: an empty or failed critique used
# to write log.txt all the same, so the enforcement layer proved a file had been
# created and nothing about whether the audit happened.
if [ "$critique_ok" = 1 ] && [ -s "$critique" ]; then
  : > "$run/ok"
fi

jstr() { cp_jstr "$1"; }
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
if [ ! -f "$run/ok" ]; then
  echo "!!! CRITIQUE FAILED: no usable critique came back (see critique.stderr)."
  echo "!!! This run is NOT counted as a round, so re-run the same command to retry."
  echo "!!! Do not ship as if the loop had audited the draft."
  echo
fi
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
