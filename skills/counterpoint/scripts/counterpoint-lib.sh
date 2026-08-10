#!/usr/bin/env bash
# counterpoint-lib.sh: the shared runtime for every Codex call in the loop.
#
# Sourced, never executed. It exists because the three phases (plan, plan
# review, critique) all shell out to the same CLI and had drifted: the MCP
# isolation fix lived in two of the wrappers and not in `codex exec review`, the
# config parsing was duplicated, and nothing anywhere was bounded in time. One
# observed run burned nine minutes of web-search calls under a networkless
# sandbox and came back with a zero-byte critique, which the enforcement layer
# then accepted as a completed phase. This file is where those three properties
# now live once: a hard time bound, a retry that distinguishes transient failure
# from a stuck model, and an empty final message treated as a failure rather than
# a result.
#
# Environment:
#   COUNTERPOINT_CODEX_TIMEOUT   seconds per Codex attempt (default 600; 0 = off)
#   COUNTERPOINT_CODEX_RETRIES   extra attempts after a non-timeout failure (default 1)
#   COUNTERPOINT_RETENTION_DAYS  run-dir retention in days (default 30; 0 = keep)

# --- config.toml -------------------------------------------------------------
# Read one top-level key from the Codex config. Stops at the first [table],
# which is correct TOML: a bare key after a table header belongs to that table,
# so only the lines before it are top level.
cp_cfg_value() {
  local key="$1" cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
  [ -f "$cfg" ] || return 0
  awk -v k="$key" '
    /^\[/ { exit }
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, ""); gsub(/"/, ""); print; exit
    }' "$cfg" 2>/dev/null || true
}

# --- reasoning effort --------------------------------------------------------
# Phases are not equally hard. Drafting a plan or reading a merged plan does not
# need the budget an audit of a finished deliverable needs, and the whole config
# was pinned at xhigh, which is the single largest latency term in a turn.
#
# The phase default is a CAP, not a setting: cp_effort_min never raises the
# user's configured effort, it only lowers it for the cheap phases. Someone who
# runs the whole loop at medium keeps medium everywhere.
cp_effort_rank() {
  case "$1" in
    minimal) echo 0 ;; low) echo 1 ;; medium) echo 2 ;;
    high) echo 3 ;; xhigh) echo 4 ;; *) echo -1 ;;
  esac
}

cp_effort_min() {
  local a="${1:-}" b="${2:-}" ra rb r
  ra="$(cp_effort_rank "$a")"; rb="$(cp_effort_rank "$b")"
  if [ "$ra" -lt 0 ]; then r="$b"
  elif [ "$rb" -lt 0 ]; then r="$a"
  elif [ "$ra" -le "$rb" ]; then r="$a"
  else r="$b"; fi
  # Floor at low. The API rejects reasoning.effort "minimal" outright whenever a
  # tool Codex exposes by default is available:
  #   "The following tools cannot be used with reasoning.effort 'minimal': web_search"
  # so a minimal cap does not make a phase cheap, it makes every call fail with a
  # 400. Found by running the wrapper against the real CLI.
  [ "$r" = "minimal" ] && r="low"
  printf '%s' "$r"
}

# --- bounded Codex invocation ------------------------------------------------
cp_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then printf 'timeout'
  elif command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout'
  else printf ''; fi
}

# cp_codex_exec OUT [--stdin FILE] -- <codex args...>
#
# OUT is the file the caller passed to `-o`; it is the contract for success, so
# an exit 0 with an empty OUT counts as a failure and not as a critique that had
# nothing to say. Codex's progress and reasoning go to this function's stderr,
# so the caller controls where they land.
#
# --stdin names the file holding the assembled prompt, and it is required for
# any call that has one: a retry cannot re-read a consumed pipe, so the second
# attempt would reach Codex with nothing and die on "No prompt provided via
# stdin". The caller buffers the prompt to a file once and every attempt is fed
# from it. Calls with no prompt on stdin (`codex exec review`) get /dev/null,
# which also keeps this from ever blocking on an inherited pipe.
#
# Retry policy: a non-zero exit or an empty OUT is retried (transient CLI,
# network, or auth hiccups are cheap to redo). A timeout is NOT retried: the
# observed hang was a model stuck in a tool loop, and a second attempt just
# spends the bound twice. Worst case is therefore one timeout, not two.
cp_codex_exec() {
  local out="$1"; shift
  local stdin_file="/dev/null"
  while [ $# -gt 0 ]; do
    case "$1" in
      --stdin) stdin_file="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  local tmo="${COUNTERPOINT_CODEX_TIMEOUT:-600}"
  local retries="${COUNTERPOINT_CODEX_RETRIES:-1}"
  local tbin; tbin="$(cp_timeout_bin)"
  local attempt=1 rc

  if [ -z "$tbin" ] && [ "$tmo" != "0" ]; then
    echo "counterpoint: no timeout(1) available; running Codex unbounded" >&2
  fi

  while :; do
    : > "$out" 2>/dev/null || true
    rc=0
    if [ -n "$tbin" ] && [ "$tmo" != "0" ]; then
      "$tbin" -k 10 "$tmo" codex "$@" < "$stdin_file" >&2 || rc=$?
    else
      codex "$@" < "$stdin_file" >&2 || rc=$?
    fi

    if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
      echo "counterpoint: codex hit the ${tmo}s bound and was killed (attempt $attempt); not retried, a timeout is a stuck run" >&2
      return 124
    fi
    if [ "$rc" = 0 ] && [ -s "$out" ]; then
      return 0
    fi

    local why="exit $rc"
    [ "$rc" = 0 ] && why="exit 0 but an empty final message"
    if [ "$attempt" -gt "$retries" ]; then
      echo "counterpoint: codex failed ($why) after $attempt attempt(s)" >&2
      [ "$rc" = 0 ] && return 3
      return "$rc"
    fi
    echo "counterpoint: codex attempt $attempt failed ($why); retrying ..." >&2
    attempt=$((attempt + 1))
  done
}

# --- artifacts ---------------------------------------------------------------
# JSON string escaping. The old inline version deleted newlines outright and left
# tabs and control characters raw, so a multi-line --task produced invalid
# meta.json. Newlines become \n instead of vanishing.
cp_jstr() {
  printf '%s' "${1:-}" | awk '
    BEGIN { ORS = "" }
    {
      gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r")
      if (NR > 1) printf "\\n"
      print
    }'
}

# Run dirs accumulate forever otherwise: each one keeps the full inlined parity
# context plus the raw reasoning stream, which is 100 KB or so per turn.
cp_gc_runs() {
  local runs="${1:-}" days="${COUNTERPOINT_RETENTION_DAYS:-30}"
  [ -d "$runs" ] || return 0
  case "$days" in ''|*[!0-9]*) return 0 ;; esac
  [ "$days" -gt 0 ] || return 0
  find "$runs" -mindepth 1 -maxdepth 1 -type d -mtime "+$days" -exec rm -rf {} + 2>/dev/null || true
}

# --- turn attribution --------------------------------------------------------
# The UserPromptSubmit hook stamps current-turn every prompt. Outside Claude Code
# there is no stamp, and the old fallback ("manual") silently disabled the
# round guard: small mode could then loop without limit. COUNTERPOINT_TURN_ID
# lets a caller supply one; otherwise runs fall into a rolling window so the
# bound still exists off-hook.
cp_turn_id() {
  local home="$1"
  if [ -n "${COUNTERPOINT_TURN_ID:-}" ]; then printf '%s' "$COUNTERPOINT_TURN_ID"; return 0; fi
  if [ -f "$home/current-turn" ]; then tr -d '[:space:]' < "$home/current-turn"; return 0; fi
  printf 'manual'
}

# Count prior runs of this turn that carry MARKER (a filename inside the run
# dir). Only runs that recorded success (the `ok` marker) count, so a failed
# Codex call does not consume the single pass small mode is allowed and lock the
# turn out of its own retry.
cp_count_runs() {
  local runs="$1" turn_id="$2" marker="$3" n=0 d
  [ -d "$runs" ] || { printf '0'; return 0; }
  local window="${COUNTERPOINT_MANUAL_WINDOW_MIN:-30}"
  for d in "$runs"/*/; do
    [ -f "${d}turn_id" ] && [ -f "${d}$marker" ] && [ -f "${d}ok" ] || continue
    if [ "$turn_id" = "manual" ]; then
      # No turn stamp to attribute against: bound by recency instead.
      [ "$(cat "${d}turn_id")" = "manual" ] || continue
      [ -n "$(find "${d}$marker" -mmin "-$window" 2>/dev/null)" ] || continue
    else
      [ "$(cat "${d}turn_id")" = "$turn_id" ] || continue
    fi
    n=$((n + 1))
  done
  printf '%s' "$n"
}
