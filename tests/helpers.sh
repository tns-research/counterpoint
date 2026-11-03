#!/usr/bin/env bash
# Shared test scaffolding: an isolated COUNTERPOINT_HOME and a fake `codex` on
# PATH, so every test is offline and free. Sourced by the test files.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CP="$root/skills/counterpoint/bin/counterpoint"
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass + 1)); else echo "FAIL: $1 (want '$3', got '$2')"; fail=$((fail + 1)); fi; }
has() { case "$2" in *"$3"*) echo "PASS: $1"; pass=$((pass + 1)) ;; *) echo "FAIL: $1 (no '$3' in: $(printf '%s' "$2" | head -3))"; fail=$((fail + 1)) ;; esac; }
finish() { echo; echo "== $pass passed, $fail failed =="; [ "$fail" = 0 ]; }

work="$(mktemp -d "${TMPDIR:-/tmp}/counterpoint-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export COUNTERPOINT_HOME="$work/home"
export COUNTERPOINT_FAKE_LOG="$work/codex.log"
export COUNTERPOINT_FAKE_COUNT="$work/codex.count"
export COUNTERPOINT_CODEX_ENV_PASSTHROUGH="COUNTERPOINT_FAKE_LOG,COUNTERPOINT_FAKE_COUNT,COUNTERPOINT_FAKE_BEHAVIOR,COUNTERPOINT_FAKE_REPLY"
unset CLAUDE_CODE_SESSION_ID COUNTERPOINT_TURN
mkdir -p "$work/bin"
# BEHAVIOR: ok (default) | fail | empty | hang | flaky (fail once, then ok)
# REPLY: the final message to write; defaults to one finding (F1) for a
# schema'd call and a plain plan otherwise.
cat > "$work/bin/codex" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COUNTERPOINT_FAKE_LOG"
env | cut -d= -f1 | sort > "$COUNTERPOINT_FAKE_LOG.env"
out=""; schema=""; prev=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; --output-schema) schema="$a" ;; esac
  prev="$a"
done
cat > "$COUNTERPOINT_FAKE_LOG.stdin"
n=1; [ -f "$COUNTERPOINT_FAKE_COUNT" ] && n=$(( $(cat "$COUNTERPOINT_FAKE_COUNT") + 1 )); echo "$n" > "$COUNTERPOINT_FAKE_COUNT"
case "${COUNTERPOINT_FAKE_BEHAVIOR:-ok}" in
  fail) echo "boom" >&2; exit 1 ;;
  empty) exit 0 ;;
  hang) sleep 60; exit 0 ;;
  flaky) [ "$n" = 1 ] && { echo "transient" >&2; exit 1; } ;;
esac
echo '{"type":"thread.started","thread_id":"thread-123"}'
reply="${COUNTERPOINT_FAKE_REPLY:-}"
if [ -z "$reply" ]; then
  case "$schema" in
    *findings.json) reply='{"verdict":"fix","summary":"one issue","findings":[{"id":"F1","severity":"major","where":"a.sh:1","problem":"p","evidence":"e","fix":"f"}]}' ;;
    *recheck.json) reply='{"verdict":"ship","summary":"fixed","unresolved":[],"findings":[]}' ;;
    *compare.json) reply='{"summary":"they differ on X","plans":[{"label":"A","scores":[{"criterion":"constraints","score":2,"why":"w"},{"criterion":"correctness","score":2,"why":"w"},{"criterion":"specificity","score":1,"why":"w"},{"criterion":"risks","score":1,"why":"w"},{"criterion":"insight","score":0,"why":"w"}],"issues":[{"where":"step 2","problem":"p","fix":"f"}],"keep":["k"]},{"label":"B","scores":[{"criterion":"constraints","score":1,"why":"w"},{"criterion":"correctness","score":1,"why":"w"},{"criterion":"specificity","score":1,"why":"w"},{"criterion":"risks","score":1,"why":"w"},{"criterion":"insight","score":0,"why":"w"}],"issues":[],"keep":[]}]}' ;;
    *) reply='1. plan step' ;;
  esac
fi
printf '%s\n' "$reply" > "$out"
FAKE
chmod +x "$work/bin/codex"
# A fake `claude` for the second plan judge; off unless a test turns it on.
export COUNTERPOINT_CLAUDE_JUDGE=0
cat > "$work/bin/claude" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COUNTERPOINT_FAKE_LOG.claude"
env | cut -d= -f1 | sort > "$COUNTERPOINT_FAKE_LOG.claude.env"
cat > "$COUNTERPOINT_FAKE_LOG.claude.stdin"
[ "${COUNTERPOINT_FAKE_CLAUDE:-ok}" = fail ] && { echo "claude down" >&2; exit 1; }
printf '{"type":"result","structured_output":%s}\n' "${COUNTERPOINT_FAKE_CLAUDE_REPLY:-null}"
FAKE
chmod +x "$work/bin/claude"
export PATH="$work/bin:$PATH"
cd "$work"
printf 'the request\n' > brief.md
printf '# AGENTS.md\nrule one\n' > agents.md
printf 'echo draft\n' > a.sh
