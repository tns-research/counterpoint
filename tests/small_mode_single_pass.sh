#!/usr/bin/env bash
# Regression test: small mode is strictly linear and never loops.
#
# Small mode is the deliberate fast lane: one produce, one critique, one revise,
# then ship, even for code with a hard verifier. Iteration is a full-mode
# property. This is enforced in counterpoint-run.sh, not just narrated: a second
# critique run in the same turn is refused in small mode, while full mode keeps
# its capped mini-loop (up to 3 rounds). This file pins that boundary so small
# cannot silently regain a loop.
#
# The cases use the critic=opus path (Codex produced, Opus critiques in session),
# which runs NO Codex subprocess, so the test is deterministic and offline: it
# exercises the round guard without spending a model call.
#
# Run: bash tests/small_mode_single_pass.sh   (exit 0 = all green)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_sh="$root/skills/counterpoint/scripts/counterpoint-run.sh"

pass=0
fail=0
ok() { if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass + 1)); else echo "FAIL: $1 (want $3, got $2)"; fail=$((fail + 1)); fi; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# Run one critique in a fresh isolated home with `nprior` prior critique runs
# already recorded for this turn. Prints "<exit>|<stderr>".
run_case() {
  local mode="$1" nprior="$2"
  local work; work="$(mktemp -d)"
  export COUNTERPOINT_HOME="$work"
  mkdir -p "$work/runs"
  echo "turn-1" > "$work/current-turn"
  local i=0
  while [ "$i" -lt "$nprior" ]; do
    mkdir -p "$work/runs/prior$i"
    echo "turn-1" > "$work/runs/prior$i/turn_id"
    : > "$work/runs/prior$i/log.txt"
    i=$((i + 1))
  done
  echo "draft body" > "$work/draft.md"
  echo "the request" > "$work/prompt.txt"
  local args=(--mode "$mode" --task t --draft "$work/draft.md" --prompt "$work/prompt.txt" --producer codex --critic opus)
  [ "$mode" = "full" ] && { echo "agreed plan" > "$work/plan.txt"; args+=(--plan "$work/plan.txt"); }
  local err code
  err="$(bash "$run_sh" "${args[@]}" 2>&1 >/dev/null)"; code=$?
  rm -rf "$work"
  printf '%s|%s' "$code" "$err"
}

# Small mode, first critique of the turn: allowed, runs the single pass.
r="$(run_case small 0)"; ok "small round 1 runs (exit 0)" "${r%%|*}" 0

# Small mode, a critique already ran this turn: refused, single-pass only.
r="$(run_case small 1)"; code="${r%%|*}"; msg="${r#*|}"
ok "small round 2 is refused (exit 2)" "$code" 2
if contains "$msg" "single-pass"; then ok "small refusal names single-pass" yes yes; else ok "small refusal names single-pass" "$msg" "single-pass"; fi

# Full mode keeps iterating: a second critique in the same turn is allowed.
r="$(run_case full 1)"; ok "full round 2 is allowed (exit 0)" "${r%%|*}" 0

# Full mode still caps the mini-loop: past 3 rounds it refuses.
r="$(run_case full 3)"; code="${r%%|*}"; msg="${r#*|}"
ok "full round 4 hits the cap (exit 2)" "$code" 2
if contains "$msg" "mini-loop cap"; then ok "full cap names the mini-loop" yes yes; else ok "full cap names the mini-loop" "$msg" "mini-loop cap"; fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" = 0 ]
