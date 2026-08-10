#!/usr/bin/env bash
# Regression tests for the code-task second pass (`codex exec review`).
#
# Three things were wrong with it. It ran after the critique although the two are
# independent, so a code turn paid both latencies end to end. It was a bare
# `codex exec review` with the user config live and stderr thrown away, which is
# exactly the configuration that let an MCP server hang a call under a
# networkless sandbox: the isolation fix had been applied to the two wrapper
# scripts and not to this call site. And the invocation itself was invalid, which
# nobody could see because the error went to /dev/null and the failure branch
# printed a tidy "(codex exec review unavailable)". `review` is a subcommand with
# its own parser: it rejects --color, and it requires an explicit target. So the
# second model-diverse pass on code tasks had never actually run.
#
# A fake `codex` on PATH keeps this offline and deterministic.
#
# Run: bash tests/code_review_parallel.sh   (exit 0 = all green)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_sh="$root/skills/counterpoint/scripts/counterpoint-run.sh"

pass=0
fail=0
ok() { if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass + 1)); else echo "FAIL: $1 (want $3, got $2)"; fail=$((fail + 1)); fi; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fakebin="$work/bin"
mkdir -p "$fakebin"
# Each call takes SLEEP seconds, so serial and parallel are distinguishable by
# the wall clock. `review` calls are logged separately from consult calls.
cat > "$fakebin/codex" <<'FAKE'
#!/usr/bin/env bash
out=""
prev=""
is_review=0
for a in "$@"; do
  case "$prev" in -o|--output-last-message) out="$a" ;; esac
  [ "$a" = "review" ] && is_review=1
  prev="$a"
done
if [ "$is_review" = 1 ]; then
  printf '%s\n' "$*" >> "$COUNTERPOINT_FAKE_REVIEW_ARGS"
  body='review finding: the diff drops a guard'
else
  printf '%s\n' "$*" >> "$COUNTERPOINT_FAKE_CONSULT_ARGS"
  body='critique: PASS on every stated constraint'
fi
sleep "${COUNTERPOINT_FAKE_SLEEP:-0}"
[ -n "$out" ] && printf '%s\n' "$body" > "$out"
exit 0
FAKE
chmod +x "$fakebin/codex"
export PATH="$fakebin:$PATH"
export COUNTERPOINT_FAKE_CONSULT_ARGS="$work/consult.log"
export COUNTERPOINT_FAKE_REVIEW_ARGS="$work/review.log"
export CODEX_HOME="$work/codex-home"
mkdir -p "$CODEX_HOME"
printf 'model = "gpt-5.4"\nmodel_reasoning_effort = "xhigh"\n' > "$CODEX_HOME/config.toml"
export COUNTERPOINT_HOME="$work/home"
export COUNTERPOINT_TURN_ID="turn-code-1"
export COUNTERPOINT_CODEX_TIMEOUT=30

echo "the request" > "$work/prompt.txt"
echo "draft body" > "$work/draft.md"

export COUNTERPOINT_FAKE_SLEEP=4
started="$(date +%s)"
out="$(bash "$run_sh" --mode small --task t --draft "$work/draft.md" --prompt "$work/prompt.txt" \
  --producer opus --critic codex --code 2>/dev/null)"
code=$?
elapsed=$(( $(date +%s) - started ))
run="$(printf '%s' "$out" | sed -n 's/^run dir: //p')"

ok "code critique run succeeds" "$code" 0
# Serial would be about 8s for two 4s calls; parallel stays near one of them.
[ "$elapsed" -lt 7 ] && ok "review runs in parallel with the critique" parallel parallel || ok "review runs in parallel with the critique" "${elapsed}s (serial)" parallel

contains "$out" "critique: PASS on every stated constraint" && ok "critique text is reported" yes yes || ok "critique text is reported" no yes
contains "$out" "=== codex exec review ===" && ok "review section is present" yes yes || ok "review section is present" no yes
contains "$out" "review finding: the diff drops a guard" && ok "review output is folded in" yes yes || ok "review output is folded in" no yes
[ -f "$run/ok" ] && ok "a successful critique is marked ok" yes yes || ok "a successful critique is marked ok" no yes

# The review call gets the same isolation and model pinning as every other call.
rargs="$(tail -n 1 "$COUNTERPOINT_FAKE_REVIEW_ARGS" 2>/dev/null || echo '')"
contains "$rargs" "--ignore-user-config" && ok "review drops the user MCP config" yes yes || ok "review drops the user MCP config" "$rargs" "--ignore-user-config"
contains "$rargs" 'model="gpt-5.4"' && ok "review re-injects the configured model" yes yes || ok "review re-injects the configured model" "$rargs" 'model="gpt-5.4"'
contains "$rargs" "--uncommitted" && ok "review targets the working diff" yes yes || ok "review targets the working diff" "$rargs" "--uncommitted"
contains "$rargs" "--color" && ok "review does not pass --color (the subcommand rejects it)" passes absent || ok "review does not pass --color (the subcommand rejects it)" absent absent
[ -s "$run/code_review.stderr" ] || [ -f "$run/code_review.stderr" ] && ok "review stderr is kept, not discarded" yes yes || ok "review stderr is kept, not discarded" no yes

# On a host where Codex's own sandbox cannot start, review silently loses its
# access to the diff and reports that it could not inspect anything, exit 0 and
# all. The bypass opt-in has to reach this call site too, or the code pass is
# decorative there.
contains "$rargs" "--dangerously-bypass-approvals-and-sandbox" && ok "review has no bypass by default" present absent || ok "review has no bypass by default" absent absent
COUNTERPOINT_FAKE_SLEEP=0 COUNTERPOINT_TURN_ID="turn-code-2" COUNTERPOINT_CODEX_BYPASS_SANDBOX=1 \
  bash "$run_sh" --mode small --task t --draft "$work/draft.md" --prompt "$work/prompt.txt" \
  --producer opus --critic codex --code >/dev/null 2>&1
rargs="$(tail -n 1 "$COUNTERPOINT_FAKE_REVIEW_ARGS")"
contains "$rargs" "--dangerously-bypass-approvals-and-sandbox" && ok "review honors the sandbox bypass opt-in" yes yes || ok "review honors the sandbox bypass opt-in" "$rargs" "bypass"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" = 0 ]
