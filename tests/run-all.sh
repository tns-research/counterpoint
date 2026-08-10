#!/usr/bin/env bash
# Run every regression test. All of them are offline: they stub `codex` with a
# fake binary on PATH, so the suite costs nothing and needs no subscription.
#
# Run: bash tests/run-all.sh   (exit 0 = all green)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
for t in "$here"/*.sh; do
  case "$t" in */run-all.sh) continue ;; esac
  echo "=== $(basename "$t")"
  bash "$t" || failed=1
  echo
done
[ "$failed" = 0 ] && echo "ALL GREEN" || echo "SOME TESTS FAILED"
exit "$failed"
