#!/usr/bin/env bash
# Regression tests for the counterpoint toggle hooks. Dependency-free bash.
#
# Headline case (the "on and off at once" incident): the global toggle is off,
# but a stale per-turn marker left over from a prior full-mode turn says "full"
# and carries the current turn id. It leaked because a session re-ran the Stop
# hook without re-stamping the turn (the workspace turn's marker survived into a
# context that shares ~/.counterpoint). Before the single-source-of-truth fix the
# Stop hook trusted that frozen marker and blocked the turn against the toggle.
# Now the Stop hook re-reads the live toggle, so it must NOT block. This file
# pins that behavior so the incoherence cannot come back.
#
# Run: bash tests/hooks_regression.sh   (exit 0 = all green)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRY="$here/../skills/counterpoint/hooks/counterpoint-hook.sh"
STOP="$here/../skills/counterpoint/hooks/counterpoint-stop-hook.sh"

pass=0
fail=0
ok() { if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass + 1)); else echo "FAIL: $1 (want $3, got $2)"; fail=$((fail + 1)); fi; }
run_stop() { local p="${1:-}"; [ -n "$p" ] || p='{}'; printf '%s' "$p" | bash "$STOP" >/dev/null 2>&1; echo $?; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export COUNTERPOINT_HOME="$work"
reset() { rm -rf "${work:?}"/* 2>/dev/null || true; }

# Headline: the exact incident. Toggle off, stale marker says full for THIS turn.
# The Stop hook must read the live toggle (off) and let the turn end.
reset
echo off > "$work/mode"
tid="stale-turn-1"
echo "$tid" > "$work/current-turn"
printf '%s\nfull\n' "$tid" > "$work/current-turn-mode"
ok "incident: toggle off + leaked marker=full does NOT block" "$(run_stop)" 0

# The entry hook purges any leaked marker on the next prompt, so nothing lingers.
reset
echo off > "$work/mode"
printf 'x\nfull\n' > "$work/current-turn-mode"
printf 'y\nsmall\n' > "$work/current-turn-manual"
printf 'ordinary message' | bash "$ENTRY" >/dev/null 2>&1
if [ -f "$work/current-turn-mode" ] || [ -f "$work/current-turn-manual" ]; then
  ok "entry hook purges leaked markers" present absent
else
  ok "entry hook purges leaked markers" absent absent
fi

# Enforcement still works: toggle on, no run artifacts, so the stop is blocked.
reset
echo small > "$work/mode"
printf 'do a task' | bash "$ENTRY" >/dev/null 2>&1
ok "toggle small + no run blocks the stop" "$(run_stop)" 2

# A run whose Codex call failed writes its artifacts but no `ok` marker, and
# leaves critique.txt empty. That used to satisfy the gate: the hook proved a
# file existed, not that anything had audited the draft. It must still block.
tid="$(cat "$work/current-turn")"
mkdir -p "$work/runs/r1"
echo "$tid" > "$work/runs/r1/turn_id"
: > "$work/runs/r1/log.txt"
: > "$work/runs/r1/critique.txt"
echo "shipped" > "$work/runs/r1/result.md"
ok "failed critique (no ok marker) still blocks the stop" "$(run_stop)" 2

# Marked ok but the critique file is empty: still not an audit.
: > "$work/runs/r1/ok"
ok "ok marker with an empty critique still blocks" "$(run_stop)" 2

# A real critique, but result.md is empty: the deliver phase did not land.
echo "the critique" > "$work/runs/r1/critique.txt"
: > "$work/runs/r1/result.md"
ok "empty result.md still blocks the stop" "$(run_stop)" 2

# ...and clears once the run artifacts for this turn are complete and successful.
echo "shipped" > "$work/runs/r1/result.md"
ok "toggle small + successful artifacts allows the stop" "$(run_stop)" 0

# Full mode needs the two plan phases too, and they are held to the same bar.
reset
echo full > "$work/mode"
printf 'do a task' | bash "$ENTRY" >/dev/null 2>&1
tid="$(cat "$work/current-turn")"
mkdir -p "$work/runs/f1"
echo "$tid" > "$work/runs/f1/turn_id"
: > "$work/runs/f1/log.txt"; : > "$work/runs/f1/ok"
echo "c" > "$work/runs/f1/critique.txt"; echo "r" > "$work/runs/f1/result.md"
ok "full without the plan phases blocks" "$(run_stop)" 2
mkdir -p "$work/runs/f2" "$work/runs/f3"
echo "$tid" > "$work/runs/f2/turn_id"; echo "plan" > "$work/runs/f2/plan_codex.txt"
echo "$tid" > "$work/runs/f3/turn_id"; echo "review" > "$work/runs/f3/plan_review.txt"
ok "full with unmarked plan phases still blocks" "$(run_stop)" 2
: > "$work/runs/f2/ok"; : > "$work/runs/f3/ok"
ok "full with successful plan phases allows the stop" "$(run_stop)" 0

# Toggle off with nothing armed: dormant, ordinary single-model turn.
reset
echo off > "$work/mode"
printf 'ordinary message' | bash "$ENTRY" >/dev/null 2>&1
ok "toggle off is dormant" "$(run_stop)" 0

# The stop_hook_active guard steps aside so a block cannot loop forever.
reset
echo small > "$work/mode"
printf 'do a task' | bash "$ENTRY" >/dev/null 2>&1
ok "stop_hook_active short-circuits to allow" "$(run_stop '{"stop_hook_active":true}')" 0

echo
echo "== $pass passed, $fail failed =="
[ "$fail" = 0 ]
