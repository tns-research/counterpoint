#!/usr/bin/env bash
# Portability regression tests: Linux and macOS from one code path.
#
# The target is a stock Mac, not a Mac somebody has already fixed with Homebrew.
# That machine has bash 3.2 at /bin/bash, BSD userland, and no timeout(1). Three
# real breakages came from forgetting that, and each has a test here:
#
#   ${effective^^} in the prompt hook (bash 4 only) raised "bad substitution",
#   the heredoc failed, the hook still exited 0, and the loop silently never ran.
#   `mktemp` with no template (GNU-only) exits with a usage error on BSD, which
#   would have killed every Codex call at its first line.
#   No timeout(1) meant the time bound, the whole reason lib/core.sh
#   exists, degraded to a printed warning on exactly the platform it was needed.
#
# Two layers, because neither alone is enough. The grep layer catches a GNU-ism
# anywhere in the tree, including in a branch no test happens to walk. The stub
# layer puts BSD-behaving date/stat/mktemp on PATH ahead of the real ones, and
# hides timeout, then runs real code through them, which catches misuse the grep
# cannot name in advance.
set -uo pipefail

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lib="$repo/skills/counterpoint/lib/core.sh"
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
# This file is excluded from its own scan: it names every banned spelling on
# purpose, both in the patterns and in the BSD stubs that emulate them.
sh_files="$( { find "$repo/skills" "$repo/tests" "$repo/tools" -name '*.sh' -type f -not -path '*/corpus/*'; echo "$repo/skills/counterpoint/bin/counterpoint"; } | grep -v "^$self\$" | sort)"

# A hit is real code, not a comment about it, and not a line that explicitly
# declares itself a guarded fallback. cp_mtime has to name `stat -c` somewhere:
# it tries the BSD spelling first and falls back, which is the correct shape, so
# it carries a `portability-ok` marker rather than being papered over by a
# looser pattern.
scan() {
  grep -nE "$1" $sh_files 2>/dev/null \
    | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' \
    | grep -v 'portability-ok' \
    || true
}

echo "portability"

# --- layer 1: no bash-4 syntax anywhere --------------------------------------
# macOS /bin/bash is 3.2.57, frozen there since 2007 over the GPLv3 licence, and
# `env bash` finds it unless the user installed a newer one and put it first.
# Each pattern below is a feature 3.2 does not have.
bash4_hits=""
for pat in \
  '\$\{[A-Za-z_][A-Za-z0-9_]*\^\^' \
  '\$\{[A-Za-z_][A-Za-z0-9_]*,,' \
  'declare[[:space:]]+-A' \
  'local[[:space:]]+-A' \
  'local[[:space:]]+-n' \
  '\bmapfile\b' \
  '\breadarray\b' \
  '\bcoproc\b' \
  '&>>' \
  '\|&'
do
  hit="$(scan "$pat")"
  [ -n "$hit" ] && bash4_hits="$bash4_hits$hit"$'\n'
done
if [ -z "$bash4_hits" ]; then
  ok "no bash-4-only syntax in any script"
else
  bad "bash-4-only syntax found:"$'\n'"$bash4_hits"
fi

# --- layer 1b: no GNU-only utility spellings ---------------------------------
# Each of these means something different, or nothing, under BSD userland.
#   date +%s%N       -> BSD date prints a literal N
#   date -r FILE     -> BSD date reads -r as seconds, not a path
#   stat -c          -> BSD stat wants -f, and GNU's %m is the mount point
#   mktemp with no template, sed -i with no suffix, grep -P, readlink -f
gnu_hits=""
for pat in \
  'date[[:space:]]+\+%s%N' \
  'date[[:space:]]+-r[[:space:]]+"?\$' \
  '\bstat[[:space:]]+-c\b' \
  '\bgrep[[:space:]]+-P\b' \
  '\breadlink[[:space:]]+-f\b' \
  '\bsed[[:space:]]+-i[[:space:]]+-e\b' \
  '\bsed[[:space:]]+-i[[:space:]]+["'"'"']?s' \
  'mktemp[[:space:]]*\)' \
  'mktemp[[:space:]]+-d[[:space:]]*\)'
do
  hit="$(scan "$pat")"
  [ -n "$hit" ] && gnu_hits="$gnu_hits$hit"$'\n'
done
if [ -z "$gnu_hits" ]; then
  ok "no GNU-only utility spellings"
else
  bad "GNU-only spellings found:"$'\n'"$gnu_hits"
fi

# --- layer 2: run against BSD-behaving stubs ---------------------------------
# The stubs reject the GNU spellings the way BSD does, so a regression fails
# here even if it slips past the greps.
work="$(mktemp -d "${TMPDIR:-/tmp}/counterpoint-port.XXXXXX")"
trap 'rm -rf "$work"' EXIT
stub="$work/bsdbin"; mkdir -p "$stub"

cat > "$stub/mktemp" <<'STUB'
#!/usr/bin/env bash
# BSD mktemp: a template is mandatory.
args=(); has_template=0
for a in "$@"; do
  case "$a" in -*) ;; *) has_template=1 ;; esac
  args+=("$a")
done
if [ "$has_template" != 1 ]; then
  echo "usage: mktemp [-d] [-q] [-t prefix] [-u] template ..." >&2
  exit 1
fi
exec /usr/bin/mktemp "${args[@]}"
STUB

cat > "$stub/date" <<'STUB'
#!/usr/bin/env bash
# BSD date: no %N, and -r takes seconds rather than a path.
out=(); for a in "$@"; do
  case "$a" in
    +*%N*) a="${a//%N/N}" ;;
  esac
  out+=("$a")
done
prev=""
for a in "${out[@]}"; do
  if [ "$prev" = "-r" ] && [ -e "$a" ]; then
    echo "date: illegal time format" >&2; exit 1
  fi
  prev="$a"
done
exec /usr/bin/date "${out[@]}"
STUB

cat > "$stub/stat" <<'STUB'
#!/usr/bin/env bash
# BSD stat: -f FORMAT, and -c is not a thing.
fmt=""; file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -c) echo "stat: illegal option -- c" >&2; exit 1 ;;
    -f) fmt="$2"; shift 2 ;;
    *) file="$1"; shift ;;
  esac
done
case "$fmt" in
  %m) exec /usr/bin/stat -c %Y "$file" ;;
  *)  exec /usr/bin/stat "$file" ;;
esac
STUB

chmod +x "$stub"/*

# Hide timeout and gtimeout: a stock Mac has neither.
bsd_path="$stub:/usr/bin:/bin"
notimeout="$work/notimeout"; mkdir -p "$notimeout"
for b in sh bash awk sed grep tr cat cp mv rm find sleep kill printf env dirname basename ls mkdir touch wc head tail sort; do
  src="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$notimeout/$b"
done
ln -sf "$stub/mktemp" "$notimeout/mktemp"
ln -sf "$stub/date"   "$notimeout/date"
ln -sf "$stub/stat"   "$notimeout/stat"

got="$(PATH="$notimeout" bash -c 'command -v timeout || echo none')"
check "the stub PATH really has no timeout(1)" "$got" "none"

# cp_mktemp / cp_mktemp_d survive BSD mktemp.
got="$(PATH="$bsd_path" bash -c ". '$lib'; f=\"\$(cp_mktemp t)\"; [ -f \"\$f\" ] && echo file; rm -f \"\$f\"" 2>&1)"
check "cp_mktemp works under BSD mktemp" "$got" "file"

got="$(PATH="$bsd_path" bash -c ". '$lib'; d=\"\$(cp_mktemp_d t)\"; [ -d \"\$d\" ] && echo dir; rmdir \"\$d\"" 2>&1)"
check "cp_mktemp_d works under BSD mktemp" "$got" "dir"

# cp_mtime returns a plausible timestamp under the real host stat. On GNU stat,
# the BSD spelling can emit non-timestamp output even when it exits successfully,
# so this pins both validation and the GNU fallback.
probe="$work/probe"; echo hi > "$probe"
got="$(bash -c ". '$lib'; cp_mtime '$probe'" 2>&1)"
case "$got" in
  ''|*[!0-9]*) bad "cp_mtime under real host stat (want digits, got '$got')" ;;
  *)
    if [ "$got" -gt 1000000000 ]; then
      ok "cp_mtime returns a plausible epoch under real host stat"
    else
      bad "cp_mtime under real host stat returned implausible epoch '$got'"
    fi
    ;;
esac

# The existing BSD spelling remains supported too.
got="$(PATH="$bsd_path" bash -c ". '$lib'; cp_mtime '$probe'" 2>&1)"
case "$got" in
  ''|*[!0-9]*) bad "cp_mtime under BSD stat (want digits, got '$got')" ;;
  *) ok "cp_mtime returns a timestamp under BSD stat" ;;
esac
got="$(PATH="$bsd_path" bash -c ". '$lib'; cp_mtime '$work/does-not-exist'" 2>&1)"
check "cp_mtime on a missing file says unknown" "$got" "unknown"

# cp_new_id has no literal N in it, which is what BSD date would leave behind.
got="$(PATH="$bsd_path" bash -c ". '$lib'; cp_new_id")"
case "$got" in
  *N*) bad "cp_new_id leaked a literal N under BSD date: $got" ;;
  *)   ok "cp_new_id is clean under BSD date" ;;
esac
a="$(PATH="$bsd_path" bash -c ". '$lib'; cp_new_id")"
b="$(PATH="$bsd_path" bash -c ". '$lib'; cp_new_id")"
if [ "$a" != "$b" ]; then ok "two turn ids differ"; else bad "two turn ids collided: $a"; fi

# The prompt hook's turn id: same property, checked on the hook itself, since
# the hook stays dependency-free and does not source the lib.
hookhome="$work/hookhome"; mkdir -p "$hookhome"
printf 'small\n' > "$hookhome/mode"
out="$(printf 'hello' | PATH="$bsd_path" COUNTERPOINT_HOME="$hookhome" \
  bash "$repo/skills/counterpoint/hooks/prompt.sh" 2>&1)"
case "$out" in
  *"bad substitution"*) bad "prompt hook hit a bash-4 expansion" ;;
  *"mode=small"*)      ok  "prompt hook injects the directive under BSD userland" ;;
  *)                    bad "prompt hook printed no directive: $(printf '%s' "$out" | head -1)" ;;
esac
stamped="$(cat "$hookhome/sessions/nosession/turn" 2>/dev/null || echo "")"
case "$stamped" in
  *N-*) bad "hook turn id kept BSD date's literal N: $stamped" ;;
  '')   bad "hook wrote no turn id" ;;
  *)    ok  "hook turn id is clean under BSD date" ;;
esac

# --- the time bound with no timeout(1) ---------------------------------------
# The point of the whole exercise: on a host without timeout(1) the bound must
# still fire, with timeout(1)'s own exit status, not a warning and an unbounded
# run.
start="$(date +%s)"
rc=0
PATH="$notimeout" bash -c ". '$lib'; cp_bound 2 -- sleep 30" >/dev/null 2>&1 || rc=$?
elapsed=$(( $(date +%s) - start ))
check "cp_bound with no timeout(1) exits 124" "$rc" "124"
if [ "$elapsed" -le 8 ]; then
  ok "cp_bound with no timeout(1) killed the child in ${elapsed}s"
else
  bad "cp_bound with no timeout(1) took ${elapsed}s (want <= 8)"
fi

rc=0
PATH="$notimeout" bash -c ". '$lib'; cp_bound 10 -- true" >/dev/null 2>&1 || rc=$?
check "cp_bound passes a fast success through" "$rc" "0"

rc=0
PATH="$notimeout" bash -c ". '$lib'; cp_bound 10 -- sh -c 'exit 7'" >/dev/null 2>&1 || rc=$?
check "cp_bound passes the child's own exit code through" "$rc" "7"

# stdin must survive the watchdog. Backgrounding the child is what makes the
# watchdog possible, and a non-interactive shell with no job control points an
# asynchronous command's stdin at /dev/null, so the prompt vanished and Codex
# died on "No prompt provided via stdin" -- on macOS only, since timeout(1)
# runs in the foreground. Every Codex call feeds its prompt this way, so this
# is the difference between the loop working on a Mac and not.
got="$(printf 'the prompt' | PATH="$notimeout" bash -c ". '$lib'; cp_bound 10 -- cat" 2>/dev/null)"
check "cp_bound passes stdin through to the child" "$got" "the prompt"

# The watchdog must not outlive the call: a leaked one would kill a later,
# unrelated process that happened to reuse the pid.
got="$(PATH="$notimeout" bash -c ". '$lib'; cp_bound 30 -- true; jobs -p | wc -l" 2>/dev/null | tr -d ' ')"
check "cp_bound leaves no background job behind" "$got" "0"

# --- JSON escaping ------------------------------------------------------------
# cp_json_escape fed a backslash used to emit it unchanged, because a gsub replacement
# is parsed twice and "\\\\" collapses to one backslash. meta.json then failed
# to parse for any task naming a path or a regex.
got="$(bash -c ". '$lib'; cp_json_escape 'C:\\tmp \"q\" x'")"
check "cp_json_escape doubles backslashes" "$got" 'C:\\tmp \"q\" x'
if command -v python3 >/dev/null 2>&1; then
  probe='a\b "c" 	tab
newline \\ end'
  json="{\"t\": \"$(bash -c ". '$lib'; cp_json_escape \"\$1\"" _ "$probe")\"}"
  if printf '%s' "$json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "cp_json_escape output parses as JSON"
  else
    bad "cp_json_escape output is not valid JSON: $json"
  fi
fi

echo
echo "portability: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
