#!/usr/bin/env bash
# Regression tests for Codex config isolation in read-only calls.
#
# The fake codex binary records argv and writes the requested -o file, so this
# checks the wrapper contract without spending a model call.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
consult="$root/skills/counterpoint/scripts/codex-consult.sh"
produce="$root/skills/counterpoint/scripts/codex-produce.sh"

pass=0
fail=0

ok() {
  if "$@"; then
    echo "PASS: $*"
    pass=$((pass + 1))
  else
    echo "FAIL: $*"
    fail=$((fail + 1))
  fi
}

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

missing() {
  case "$1" in
    *"$2"*) return 1 ;;
    *) return 0 ;;
  esac
}

work="$(mktemp -d "${TMPDIR:-/tmp}/counterpoint-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fakebin="$work/bin"
mkdir -p "$fakebin"
cat > "$fakebin/codex" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COUNTERPOINT_FAKE_CODEX_ARGS"
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then
    out="$arg"
  fi
  prev="$arg"
done
cat >/dev/null
printf 'fake codex result\n' > "$out"
FAKE
chmod +x "$fakebin/codex"

export PATH="$fakebin:$PATH"
export COUNTERPOINT_FAKE_CODEX_ARGS="$work/args.log"
export CODEX_HOME="$work/codex-home"
mkdir -p "$CODEX_HOME"
cat > "$CODEX_HOME/config.toml" <<'TOML'
model = "gpt-5.4"
model_reasoning_effort = "xhigh"

[mcp_servers.zo]
command = "mcp-remote"
args = ["https://example.invalid/mcp"]
TOML

printf 'review this' | "$consult" -C "$work" >/dev/null
consult_args="$(tail -n 1 "$COUNTERPOINT_FAKE_CODEX_ARGS")"
ok contains "$consult_args" "--ignore-user-config"
ok contains "$consult_args" "model=\"gpt-5.4\""
ok contains "$consult_args" "model_reasoning_effort=\"xhigh\""

printf 'produce text' | "$produce" -C "$work" >/dev/null
produce_text_args="$(tail -n 1 "$COUNTERPOINT_FAKE_CODEX_ARGS")"
ok contains "$produce_text_args" "--ignore-user-config"
ok contains "$produce_text_args" "model=\"gpt-5.4\""
ok contains "$produce_text_args" "model_reasoning_effort=\"xhigh\""

printf 'produce files' | "$produce" -C "$work" --write "$work/out" >/dev/null
produce_write_args="$(tail -n 1 "$COUNTERPOINT_FAKE_CODEX_ARGS")"
ok missing "$produce_write_args" "--ignore-user-config"
ok contains "$produce_write_args" "-C $work/out"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" = 0 ]
