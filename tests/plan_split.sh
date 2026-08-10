#!/usr/bin/env bash
# Regression tests for the split joint-planning front-end (F1).
#
# Synchronously, Opus writes its plan, then blocks on Codex's. The Codex plan
# call is about a minute at the median and much worse in the tail, and all of it
# is dead time. The split runs it in the background while Opus drafts.
#
# The property that must survive the change is independence: the two plans are
# drafted without sight of each other. It holds by construction rather than by
# ordering, and both halves are pinned here. Codex never sees Opus's plan (the
# planning prompt is assembled from the request and the resources only), and
# Opus cannot see Codex's until --collect, because the answer lands in a hidden
# pending file that only collect promotes to plan_codex.txt.
#
# Run: bash tests/plan_split.sh   (exit 0 = all green)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plan_sh="$root/skills/counterpoint/scripts/counterpoint-plan.sh"

pass=0
fail=0
ok() { if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass + 1)); else echo "FAIL: $1 (want $3, got $2)"; fail=$((fail + 1)); fi; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fakebin="$work/bin"
mkdir -p "$fakebin"
cat > "$fakebin/codex" <<'FAKE'
#!/usr/bin/env bash
out=""
prev=""
for a in "$@"; do
  case "$prev" in -o|--output-last-message) out="$a" ;; esac
  prev="$a"
done
# Record what Codex was actually shown, so the test can assert the planning
# prompt never carried Opus's plan.
cat > "$COUNTERPOINT_FAKE_STDIN" 2>/dev/null || true
sleep "${COUNTERPOINT_FAKE_SLEEP:-0}"
[ "${COUNTERPOINT_FAKE_BEHAVIOR:-ok}" = "fail" ] && exit 1
[ -n "$out" ] && printf 'codex plan: step 1, step 2\n' > "$out"
exit 0
FAKE
chmod +x "$fakebin/codex"
export PATH="$fakebin:$PATH"
export COUNTERPOINT_FAKE_STDIN="$work/codex-stdin.txt"
export CODEX_HOME="$work/codex-home"
mkdir -p "$CODEX_HOME"
printf 'model = "gpt-5.4"\nmodel_reasoning_effort = "xhigh"\n' > "$CODEX_HOME/config.toml"
export COUNTERPOINT_HOME="$work/home"
export COUNTERPOINT_TURN_ID="turn-split-1"
export COUNTERPOINT_CODEX_TIMEOUT=20

echo "the request" > "$work/prompt.txt"
echo "AGENTS constraint: ship nothing unverified" > "$work/AGENTS.md"
printf 'opus plan: do the thing carefully\n' > "$work/opus-plan.txt"

# --- launch returns immediately, before Codex has answered -------------------
export COUNTERPOINT_FAKE_SLEEP=4
started="$(date +%s)"
out="$(bash "$plan_sh" --launch --task t --prompt "$work/prompt.txt" --resource "$work/AGENTS.md" 2>/dev/null)"
elapsed=$(( $(date +%s) - started ))
run="$(printf '%s' "$out" | sed -n 's/^run dir: //p')"
[ "$elapsed" -lt 3 ] && ok "launch returns without waiting for Codex" fast fast || ok "launch returns without waiting for Codex" "${elapsed}s" fast
[ -n "$run" ] && ok "launch prints a run dir" yes yes || ok "launch prints a run dir" no yes

# Codex's answer is not readable as plan_codex.txt while Opus is still drafting.
[ -f "$run/plan_codex.txt" ] && ok "codex plan stays hidden until collect" visible hidden || ok "codex plan stays hidden until collect" hidden hidden

# --- collect waits for the background call and records both plans ------------
out="$(bash "$plan_sh" --collect --run "$run" --opus-plan "$work/opus-plan.txt" 2>/dev/null)"
code=$?
ok "collect succeeds" "$code" 0
contains "$out" "codex plan: step 1" && ok "collect prints Codex's plan" yes yes || ok "collect prints Codex's plan" no yes
[ -s "$run/plan_codex.txt" ] && ok "collect promotes the pending plan" yes yes || ok "collect promotes the pending plan" no yes
[ -s "$run/plan_opus.txt" ] && ok "collect records the Opus plan" yes yes || ok "collect records the Opus plan" no yes
[ -f "$run/ok" ] && ok "a successful plan phase is marked ok" yes yes || ok "a successful plan phase is marked ok" no yes
[ -f "$run/.plan_codex.pending" ] && ok "collect clears the pending file" present absent || ok "collect clears the pending file" absent absent

# What Codex was actually shown (asserted after collect, so the background call
# has certainly run). The planning prompt carries the request and the resource, and
# never Opus's plan: that is what makes the two plans independent.
sent="$(cat "$COUNTERPOINT_FAKE_STDIN" 2>/dev/null || echo '')"
contains "$sent" "the request" && ok "codex prompt carries the request" yes yes || ok "codex prompt carries the request" no yes
contains "$sent" "ship nothing unverified" && ok "codex prompt inlines the resource" yes yes || ok "codex prompt inlines the resource" no yes
contains "$sent" "opus plan" && ok "codex prompt never carries the Opus plan" leaked clean || ok "codex prompt never carries the Opus plan" clean clean


# --- a failed background plan is not recorded as a completed phase -----------
export COUNTERPOINT_FAKE_BEHAVIOR=fail
export COUNTERPOINT_FAKE_SLEEP=0
out="$(bash "$plan_sh" --launch --task t --prompt "$work/prompt.txt" 2>/dev/null)"
run2="$(printf '%s' "$out" | sed -n 's/^run dir: //p')"
out="$(bash "$plan_sh" --collect --run "$run2" --opus-plan "$work/opus-plan.txt" 2>/dev/null)"
[ -f "$run2/ok" ] && ok "a failed plan phase is NOT marked ok" marked unmarked || ok "a failed plan phase is NOT marked ok" unmarked unmarked
contains "$out" "CODEX PLAN FAILED" && ok "collect says the plan failed" yes yes || ok "collect says the plan failed" no yes
unset COUNTERPOINT_FAKE_BEHAVIOR

# --- the synchronous path still works unchanged ------------------------------
out="$(bash "$plan_sh" --task t --prompt "$work/prompt.txt" --opus-plan "$work/opus-plan.txt" 2>/dev/null)"
run3="$(printf '%s' "$out" | sed -n 's/^run dir: //p')"
[ -s "$run3/plan_codex.txt" ] && [ -f "$run3/ok" ] && ok "sync mode still records a plan" yes yes || ok "sync mode still records a plan" no yes

# --collect refuses a run that was never launched, instead of hanging on it.
bash "$plan_sh" --collect --run "$run3" --opus-plan "$work/opus-plan.txt" >/dev/null 2>&1
ok "collect refuses a non-launched run" "$?" 2

echo
echo "== $pass passed, $fail failed =="
[ "$fail" = 0 ]
