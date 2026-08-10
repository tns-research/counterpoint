#!/usr/bin/env bash
# Regression tests for the Codex sandbox decision.
#
# The failure being pinned: on a host where Codex's bubblewrap sandbox cannot
# start (gVisor here, but any namespace-restricted container does it), every
# shell command Codex runs fails, and the model answers from no evidence while
# exiting 0. Measured on the real CLI: `codex exec review --uncommitted` against
# a repo with a planted regression returned 151 bytes of "No actionable findings
# were identified. However, confidence is low because the repository could not
# be inspected due to a sandbox initialization error." Exit 0, output non-empty,
# so every downstream check read it as a completed review. The same invocation
# with the bypass found the regression.
#
# So the decision must not be an env var the user has to know about. It is
# probed, and the probe is what these tests drive: a fake `bwrap` on PATH stands
# in for the host, failing on --unshare-net the way a sandboxed host does.
#
# Run: bash tests/sandbox_bypass.sh   (exit 0 = all green)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lib="$root/skills/counterpoint/scripts/counterpoint-lib.sh"

pass=0
fail=0
ok() { if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass + 1)); else echo "FAIL: $1 (want $3, got $2)"; fail=$((fail + 1)); fi; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

work="$(mktemp -d "${TMPDIR:-/tmp}/counterpoint-sandbox.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fakebin="$work/bin"
mkdir -p "$fakebin"

# The stub mirrors what the real bwrap does on a restricted host: a plain
# unshare works, adding a network namespace does not.
cat > "$fakebin/bwrap" <<'FAKE'
#!/usr/bin/env bash
case "${COUNTERPOINT_FAKE_BWRAP:-ok}" in
  broken)
    for a in "$@"; do
      if [ "$a" = "--unshare-net" ]; then
        echo "bwrap: Creating new namespace failed: Operation not permitted" >&2
        exit 1
      fi
    done
    exit 0
    ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$fakebin/bwrap"

# Ask the library, in a clean shell, with PATH pointed at the stub.
ask() {
  local fn="$1" bwrap_mode="$2" envvar="$3"
  local script="$work/ask.sh"
  cat > "$script" <<EOF
. "$lib"
$fn
EOF
  if [ "$envvar" = "unset" ]; then
    PATH="$fakebin:$PATH" COUNTERPOINT_FAKE_BWRAP="$bwrap_mode" \
      env -u COUNTERPOINT_CODEX_BYPASS_SANDBOX bash "$script" 2>"$work/err"
  else
    PATH="$fakebin:$PATH" COUNTERPOINT_FAKE_BWRAP="$bwrap_mode" \
      COUNTERPOINT_CODEX_BYPASS_SANDBOX="$envvar" bash "$script" 2>"$work/err"
  fi
}

echo "--- probe ---"

ok "a working bwrap reads as a usable sandbox" "$(ask 'cp_sandbox_usable && printf yes || printf no' ok unset)" "yes"
ok "a bwrap that cannot unshare net reads as unusable" \
   "$(ask 'cp_sandbox_usable && printf yes || printf no' broken unset)" "no"

echo
echo "--- decision ---"

ok "usable sandbox is kept (no bypass)" "$(ask cp_sandbox_bypass ok unset)" "0"
ok "unusable sandbox turns the bypass on by itself" "$(ask cp_sandbox_bypass broken unset)" "1"
ok "an explicit 1 wins over a working sandbox" "$(ask cp_sandbox_bypass ok 1)" "1"
ok "an explicit 0 wins over a broken sandbox" "$(ask cp_sandbox_bypass broken 0)" "0"

echo
echo "--- what the operator is told ---"

ask 'cp_sandbox_announce "codex exec review" "$(cp_sandbox_bypass)"' broken unset >/dev/null
msg="$(cat "$work/err")"
if contains "$msg" "cannot start on this host"; then
  echo "PASS: an automatic bypass is announced, not silent"; pass=$((pass + 1))
else
  echo "FAIL: an automatic bypass is announced, not silent (got: $msg)"; fail=$((fail + 1))
fi

ask 'cp_sandbox_announce "codex exec review" "$(cp_sandbox_bypass)"' broken 0 >/dev/null
msg="$(cat "$work/err")"
if contains "$msg" "WARNING"; then
  echo "PASS: refusing the bypass on a broken host warns that the pass will be blind"; pass=$((pass + 1))
else
  echo "FAIL: refusing the bypass on a broken host warns that the pass will be blind (got: $msg)"; fail=$((fail + 1))
fi

ask 'cp_sandbox_announce "codex exec review" "$(cp_sandbox_bypass)"' ok unset >/dev/null
msg="$(cat "$work/err")"
if [ -z "$msg" ]; then
  echo "PASS: a healthy host says nothing"; pass=$((pass + 1))
else
  echo "FAIL: a healthy host says nothing (got: $msg)"; fail=$((fail + 1))
fi

echo
echo "--- the review call site ---"

# The flag has to reach the actual invocation, and the blind case has to be
# failed rather than appended as a verdict. Both are read out of the source
# rather than run, because running them means a Codex call.
run="$root/skills/counterpoint/scripts/counterpoint-run.sh"
src="$(cat "$run")"
if contains "$src" 'review_bypass="$(cp_sandbox_bypass)"'; then
  echo "PASS: the review path asks the library for the decision"; pass=$((pass + 1))
else
  echo "FAIL: the review path asks the library for the decision"; fail=$((fail + 1))
fi
if contains "$src" '[ "$review_bypass" = "1" ] && rargs+=(--dangerously-bypass-approvals-and-sandbox)'; then
  echo "PASS: the decision is what adds the flag"; pass=$((pass + 1))
else
  echo "FAIL: the decision is what adds the flag"; fail=$((fail + 1))
fi
if contains "$src" 'Its verdict is discarded rather than reported as a clean review'; then
  echo "PASS: a blind review is discarded, not reported"; pass=$((pass + 1))
else
  echo "FAIL: a blind review is discarded, not reported"; fail=$((fail + 1))
fi
# The old spelling read the env var straight at the call sites, which is what
# made the whole thing opt-in and therefore off by default where it mattered.
if contains "$src" 'COUNTERPOINT_CODEX_BYPASS_SANDBOX:-0'; then
  echo "FAIL: the review path still reads the env var directly"; fail=$((fail + 1))
else
  echo "PASS: the review path no longer reads the env var directly"; pass=$((pass + 1))
fi
produce="$(cat "$root/skills/counterpoint/scripts/codex-produce.sh")"
if contains "$produce" 'COUNTERPOINT_CODEX_BYPASS_SANDBOX:-0'; then
  echo "FAIL: the write path still reads the env var directly"; fail=$((fail + 1))
else
  echo "PASS: the write path no longer reads the env var directly"; pass=$((pass + 1))
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" = 0 ]
