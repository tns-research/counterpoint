#!/usr/bin/env bash
# Regression tests for the bounded Codex call: timeout, retry, empty-output
# handling, and the per-phase reasoning-effort cap.
#
# The failure this pins down was observed in a real run: a critic went into a
# tool loop under a networkless sandbox, ran for nine minutes, and returned a
# zero-byte final message. Nothing bounded it and nothing noticed, because an
# exit 0 with an empty answer looked exactly like a critique that had nothing to
# say. So: a hard time bound, a retry for transient failures, no retry after a
# timeout (a stuck run stays stuck and would just spend the bound twice), and an
# empty final message treated as a failure.
#
# A fake `codex` on PATH makes all of this deterministic and offline.
#
# Run: bash tests/codex_bounds.sh   (exit 0 = all green)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
consult="$root/skills/counterpoint/scripts/codex-consult.sh"
lib="$root/skills/counterpoint/scripts/counterpoint-lib.sh"

pass=0
fail=0
ok() { if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass + 1)); else echo "FAIL: $1 (want $3, got $2)"; fail=$((fail + 1)); fi; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

work="$(mktemp -d "${TMPDIR:-/tmp}/counterpoint-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fakebin="$work/bin"
mkdir -p "$fakebin"
# BEHAVIOR is read per invocation, so a single fake covers every case:
#   ok      -> write the final message, exit 0
#   empty   -> exit 0 with nothing written (the observed silent failure)
#   fail    -> exit 1 without writing
#   hang    -> sleep past any test bound
#   flaky   -> fail the first invocation, succeed after
cat > "$fakebin/codex" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COUNTERPOINT_FAKE_ARGS"
out=""
prev=""
for a in "$@"; do
  case "$prev" in -o|--output-last-message) out="$a" ;; esac
  prev="$a"
done
# The real CLI dies with "No prompt provided via stdin." when it is invoked with
# a trailing `-` and gets nothing. Reproduce that, because a retry that replays a
# consumed pipe hits exactly this and the fake would otherwise hide it.
stdin_data="$(cat)"
if [ -z "$stdin_data" ]; then
  printf 'No prompt provided via stdin.\n' >&2
  exit 42
fi
n=1
[ -f "$COUNTERPOINT_FAKE_COUNT" ] && n=$(( $(cat "$COUNTERPOINT_FAKE_COUNT") + 1 ))
printf '%s' "$n" > "$COUNTERPOINT_FAKE_COUNT"
case "${COUNTERPOINT_FAKE_BEHAVIOR:-ok}" in
  empty) exit 0 ;;
  fail)  exit 1 ;;
  hang)  sleep 30; exit 0 ;;
  flaky) [ "$n" = 1 ] && exit 1; [ -n "$out" ] && printf 'recovered\n' > "$out"; exit 0 ;;
  *)     [ -n "$out" ] && printf 'fake codex result\n' > "$out"; exit 0 ;;
esac
FAKE
chmod +x "$fakebin/codex"
export PATH="$fakebin:$PATH"
export COUNTERPOINT_FAKE_ARGS="$work/args.log"
export COUNTERPOINT_FAKE_COUNT="$work/count"
export CODEX_HOME="$work/codex-home"
mkdir -p "$CODEX_HOME"
printf 'model = "gpt-5.4"\nmodel_reasoning_effort = "xhigh"\n' > "$CODEX_HOME/config.toml"

# Run one consult. Prints "<exit>|<invocations>".
run_consult() {
  local behavior="$1"; shift
  : > "$COUNTERPOINT_FAKE_ARGS"
  printf '0' > "$COUNTERPOINT_FAKE_COUNT"
  local code
  COUNTERPOINT_FAKE_BEHAVIOR="$behavior" bash -c "printf 'prompt' | '$consult' $*" >/dev/null 2>&1
  code=$?
  printf '%s|%s' "$code" "$(cat "$COUNTERPOINT_FAKE_COUNT")"
}

# A healthy call: one invocation, exit 0.
export COUNTERPOINT_CODEX_TIMEOUT=5
export COUNTERPOINT_CODEX_RETRIES=1
r="$(run_consult ok)"; ok "healthy call succeeds in one invocation" "$r" "0|1"

# Exit 0 with an empty final message is a failure, not an empty critique, and it
# is retried once before giving up with the dedicated code 3.
r="$(run_consult empty)"; ok "empty final message fails after a retry" "$r" "3|2"

# A hard failure is transient-shaped, so it is retried once.
r="$(run_consult fail)"; ok "hard failure is retried once" "$r" "1|2"

# ...and the retry is what makes a flaky call succeed. The fake refuses an empty
# stdin the way the real CLI does, so this also pins the prompt being replayed on
# the retry rather than read from an already-consumed pipe (exit 42 here).
r="$(run_consult flaky)"; ok "flaky call recovers on the retry" "$r" "0|2"

# A hang is bounded and NOT retried: retrying a stuck run spends the bound twice.
export COUNTERPOINT_CODEX_TIMEOUT=2
r="$(run_consult hang)"; ok "hang is killed at the bound, no retry" "$r" "124|1"
export COUNTERPOINT_CODEX_TIMEOUT=5

# Retries can be turned off entirely.
r="$(COUNTERPOINT_CODEX_RETRIES=0 run_consult fail)"
ok "retries=0 gives up immediately" "$r" "1|1"

# --- the effort cap ----------------------------------------------------------
# -e is a cap and not a setting: it lowers the configured effort for a cheap
# phase and must never raise it.
: > "$COUNTERPOINT_FAKE_ARGS"; printf '0' > "$COUNTERPOINT_FAKE_COUNT"
printf 'prompt' | "$consult" -e high >/dev/null 2>&1
a="$(tail -n 1 "$COUNTERPOINT_FAKE_ARGS")"
if contains "$a" 'model_reasoning_effort="high"'; then ok "-e high caps xhigh down to high" yes yes
else ok "-e high caps xhigh down to high" "$a" 'high'; fi

printf 'model_reasoning_effort = "medium"\n' > "$CODEX_HOME/config.toml"
: > "$COUNTERPOINT_FAKE_ARGS"
printf 'prompt' | "$consult" -e xhigh >/dev/null 2>&1
a="$(tail -n 1 "$COUNTERPOINT_FAKE_ARGS")"
if contains "$a" 'model_reasoning_effort="medium"'; then ok "-e xhigh never raises a medium config" yes yes
else ok "-e xhigh never raises a medium config" "$a" 'medium'; fi

# "minimal" is not a usable effort: the API refuses it whenever a default tool is
# exposed ("cannot be used with reasoning.effort 'minimal': web_search"), so a
# minimal cap would turn every call into a 400 instead of a cheap one. It floors
# to low.
printf 'model_reasoning_effort = "xhigh"\n' > "$CODEX_HOME/config.toml"
: > "$COUNTERPOINT_FAKE_ARGS"
printf 'prompt' | "$consult" -e minimal >/dev/null 2>&1
a="$(tail -n 1 "$COUNTERPOINT_FAKE_ARGS")"
if contains "$a" 'model_reasoning_effort="low"'; then ok "minimal floors to low" yes yes
else ok "minimal floors to low" "$a" 'low'; fi

# --- artifact helpers --------------------------------------------------------
# shellcheck source=../skills/counterpoint/scripts/counterpoint-lib.sh
. "$lib"

# JSON escaping used to delete newlines and leave tabs raw, so a multi-line
# --task produced invalid meta.json.
got="$(cp_jstr "$(printf 'a\tb\nc"d')")"
ok "cp_jstr escapes tabs, quotes and newlines" "$got" 'a\tb\nc\"d'

# Run dirs are pruned by age so the archive stops growing without bound.
runs="$work/runs"; mkdir -p "$runs/old" "$runs/new"
touch -d '90 days ago' "$runs/old" 2>/dev/null || touch -t 202001010000 "$runs/old"
COUNTERPOINT_RETENTION_DAYS=30 cp_gc_runs "$runs"
[ -d "$runs/old" ] && ok "gc removes an aged run dir" present absent || ok "gc removes an aged run dir" absent absent
[ -d "$runs/new" ] && ok "gc keeps a fresh run dir" present present || ok "gc keeps a fresh run dir" absent present

echo
echo "== $pass passed, $fail failed =="
[ "$fail" = 0 ]
