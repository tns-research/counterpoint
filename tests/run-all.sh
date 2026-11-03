#!/usr/bin/env bash
# Run every regression test. All of them are offline: they stub `codex` with a
# fake binary on PATH, so the suite costs nothing and needs no subscription.
#
# Run: bash tests/run-all.sh   (exit 0 = all green)
# Every sibling *.sh file is discovered below, so adding a test file wires it in.
#
# The suite runs twice when it can. The second pass shims `bash` on PATH to a
# bash 3.2 if one is installed, which is what macOS ships as /bin/bash and what
# `env bash` finds on a Mac with no newer bash ahead of it. Shimming PATH rather
# than threading an interpreter variable through every test file reproduces the Mac
# faithfully: the shebangs resolve to 3.2, and so does every `bash "$script"`
# inside a test. Point COUNTERPOINT_TEST_BASH32 at a build to force one; the
# second pass is skipped with a note when no 3.2 is around, so this never fails
# a machine for not having one.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_suite() {
  local failed=0 t
  for t in "$here"/*.sh; do
    case "$t" in */run-all.sh|*/helpers.sh) continue ;; esac
    echo "=== $(basename "$t")"
    bash "$t" || failed=1
    echo
  done
  return "$failed"
}

# The inner pass: already shimmed, just run and report.
if [ -n "${COUNTERPOINT_TEST_INNER:-}" ]; then
  run_suite
  exit $?
fi

overall=0
echo "### pass 1: $(bash --version | head -1)"
echo
run_suite || overall=1

find_bash32() {
  local c v
  for c in "${COUNTERPOINT_TEST_BASH32:-}" /opt/bash32/bin/bash /bin/bash \
           /usr/local/bin/bash-3.2 /opt/homebrew/bin/bash-3.2; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    v="$("$c" --version 2>/dev/null | head -1)"
    case "$v" in *"version 3."*) printf '%s' "$c"; return 0 ;; esac
  done
  return 1
}

b32="$(find_bash32 || true)"
echo
if [ -z "$b32" ]; then
  echo "### pass 2 skipped: no bash 3.2 found (set COUNTERPOINT_TEST_BASH32 to add one)."
  echo "### tests/portability.sh still enforces the bash-3.2 syntax rules by grep."
else
  echo "### pass 2: $("$b32" --version | head -1) shimmed onto PATH as \`bash\`"
  echo
  shim="$(mktemp -d "${TMPDIR:-/tmp}/counterpoint-bash32.XXXXXX")"
  ln -sf "$b32" "$shim/bash"
  PATH="$shim:$PATH" COUNTERPOINT_TEST_INNER=1 "$b32" "$here/run-all.sh" || overall=1
  rm -rf "$shim"
fi

echo
[ "$overall" = 0 ] && echo "ALL GREEN" || echo "SOME TESTS FAILED"
exit "$overall"
