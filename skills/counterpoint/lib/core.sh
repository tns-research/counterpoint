#!/usr/bin/env bash
# core.sh: the portable floor every counterpoint command stands on. Sourced, never run.
#
# Linux and stock macOS from one code path: bash 3.2 syntax only (no ${v^^},
# declare -A, mapfile), no GNU-only flags (mktemp always gets a template, no
# stat -c without a fallback, no date +%N), and no assumption that timeout(1)
# exists. tests/portability.sh enforces this.

cp_mktemp() {
  mktemp "${TMPDIR:-/tmp}/counterpoint.${1:-tmp}.XXXXXX"
}
cp_mktemp_d() {
  mktemp -d "${TMPDIR:-/tmp}/counterpoint.${1:-dir}.XXXXXX"
}
cp_mtime() {
  local f="$1" out
  [ -e "$f" ] || { printf 'unknown'; return 0; }
  out="$(stat -f %m "$f" 2>/dev/null)" || out=""
  case "$out" in ''|*[!0-9]*) ;; *) printf '%s' "$out"; return 0 ;; esac
  out="$(stat -c %Y "$f" 2>/dev/null)" || out=""   # portability-ok: GNU fallback; captured output is accepted only when all digits
  case "$out" in ''|*[!0-9]*) ;; *) printf '%s' "$out"; return 0 ;; esac
  printf 'unknown'
}
cp_abs_path() {
  local path="$1" dir base
  case "$path" in
    /*) printf '%s' "$path" ;;
    *)
      dir="$(dirname "$path")"
      base="$(basename "$path")"
      dir="$(cd "$dir" 2>/dev/null && pwd)" || return 1
      printf '%s/%s' "$dir" "$base"
      ;;
  esac
}
cp_num() {
  local value="$1" default="$2" name="$3"
  case "$value" in
    ''|*[!0-9]*)
      echo "counterpoint: WARNING $name must be a non-negative integer; using $default" >&2
      printf '%s' "$default"
      ;;
    *) printf '%s' "$value" ;;
  esac
}

# A unique id on both platforms: BSD date has no %N.
cp_new_id() {
  printf '%s-%s-%s' "$(date +%s)" "$$" "${RANDOM:-0}"
}

# --- Codex sandbox ------------------------------------------------------------
# Probe the capability rather than fingerprint the host: Codex's Linux sandbox
# needs user namespaces, which gVisor-style containers refuse. macOS uses Seatbelt.
cp_sandbox_usable() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) return 0 ;;   # Seatbelt, no namespaces involved
  esac
  if command -v bwrap >/dev/null 2>&1; then
    bwrap --unshare-net --ro-bind / / --dev /dev /bin/true >/dev/null 2>&1 && return 0
    return 1
  fi
  grep -qi 'gvisor' /proc/version 2>/dev/null && return 1
  return 0   # unknown host: assume the sandbox works rather than weaken it on a guess
}

# --- time bound ---------------------------------------------------------------
# timeout(1) where it exists, gtimeout for Homebrew coreutils, a shell watchdog
# otherwise (every stock Mac). Exit 124 means expired on every path; 0 disables.
cp_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then printf 'timeout'
  elif command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout'
  else printf ''; fi
}
cp_run_bounded() {
  local tmo="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local flag; flag="$(cp_mktemp bound)"
  rm -f "$flag"

  # The child's stdin is handed over explicitly. A non-interactive shell with no
  # job control redirects an asynchronous command's stdin from /dev/null, so
  # backgrounding the child silently dropped the prompt: `codex` then died on
  # "No prompt provided via stdin", twice, since the retry replayed the same
  # nothing. It only ever showed on the watchdog path (timeout(1) runs in the
  # foreground and inherits stdin normally), which is to say only on macOS.
  # Found by a live run with timeout(1) hidden from PATH.
  exec 3<&0
  "$@" <&3 &
  local cmd_pid=$!
  exec 3<&-

  (
    waited=0
    while [ "$waited" -lt "$tmo" ]; do
      kill -0 "$cmd_pid" 2>/dev/null || exit 0
      sleep 1
      waited=$((waited + 1))
    done
    kill -0 "$cmd_pid" 2>/dev/null || exit 0
    : > "$flag"
    kill -TERM "$cmd_pid" 2>/dev/null
    slept=0
    while [ "$slept" -lt 10 ]; do
      kill -0 "$cmd_pid" 2>/dev/null || exit 0
      sleep 1
      slept=$((slept + 1))
    done
    kill -KILL "$cmd_pid" 2>/dev/null
  ) &
  local wd_pid=$!

  local rc=0
  wait "$cmd_pid" || rc=$?
  kill -TERM "$wd_pid" 2>/dev/null || true
  wait "$wd_pid" 2>/dev/null || true

  if [ -f "$flag" ]; then rc=124; fi
  rm -f "$flag"
  return "$rc"
}
cp_bound() {
  local tmo="$1"; shift
  [ "${1:-}" = "--" ] && shift
  if [ "$tmo" = "0" ]; then "$@"; return $?; fi
  local tbin; tbin="$(cp_timeout_bin)"
  if [ -n "$tbin" ]; then "$tbin" -k 10 "$tmo" "$@"; return $?; fi
  cp_run_bounded "$tmo" -- "$@"
}

# --- minimal Codex environment -------------------------------------------------
# Codex authenticates from ~/.codex/auth.json, so it never needs the caller's
# exported keys. Build its environment by name; COUNTERPOINT_CODEX_ENV_PASSTHROUGH
# (comma-separated names) is the explicit escape hatch.
CP_CODEX_ENV_ARGS=()
cp_codex_env_prepare() {
  CP_CODEX_ENV_ARGS=()
  local name names
  names="HOME PATH USER LOGNAME SHELL LANG LC_ALL TERM TMPDIR CODEX_HOME"
  names="$names $(printf '%s' "${COUNTERPOINT_CODEX_ENV_PASSTHROUGH:-}" | tr ',' ' ')"
  for name in $names; do
    case "$name" in
      [0-9]*|*[!A-Za-z0-9_]*)
        echo "counterpoint: WARNING dropping malformed passthrough name: $name" >&2; continue ;;
    esac
    [ "${!name+x}" = "x" ] && CP_CODEX_ENV_ARGS+=("$name=${!name}")
  done
  return 0
}

# cp_codex_exec OUT STDIN_FILE -- <codex args...>
# OUT is the -o file and the success contract: exit 0 with an empty OUT is a
# failure. Non-timeout failures are retried COUNTERPOINT_CODEX_RETRIES times (the
# prompt is a file, so a retry re-reads it); a timeout is never retried, since a
# stuck run stays stuck. Codex's JSONL events go to stdout, progress to stderr.
cp_codex_exec() {
  local out="$1" stdin_file="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  local tmo retries attempt=1 rc
  tmo="$(cp_num "${COUNTERPOINT_CODEX_TIMEOUT-600}" 600 COUNTERPOINT_CODEX_TIMEOUT)"
  retries="$(cp_num "${COUNTERPOINT_CODEX_RETRIES-1}" 1 COUNTERPOINT_CODEX_RETRIES)"
  cp_codex_env_prepare
  while :; do
    : > "$out"
    rc=0
    cp_bound "$tmo" -- env -i ${CP_CODEX_ENV_ARGS+"${CP_CODEX_ENV_ARGS[@]}"} codex "$@" < "$stdin_file" || rc=$?
    if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
      echo "counterpoint: codex hit the ${tmo}s bound; not retried" >&2
      return 124
    fi
    [ "$rc" = 0 ] && [ -s "$out" ] && return 0
    if [ "$attempt" -gt "$retries" ]; then
      echo "counterpoint: codex failed (exit $rc) after $attempt attempt(s)" >&2
      [ "$rc" = 0 ] && return 3
      return "$rc"
    fi
    echo "counterpoint: codex attempt $attempt failed (exit $rc); retrying" >&2
    attempt=$((attempt + 1))
  done
}

# --- JSON without jq ---------------------------------------------------------------
cp_json_escape() {
  printf '%s' "${1:-}" | LC_ALL=C awk '
    BEGIN {
      ORS = ""
      for (n = 1; n < 32; n++) control[sprintf("%c", n)] = sprintf("\\u%04x", n)
      control[sprintf("%c", 8)] = "\\b"
      control[sprintf("%c", 9)] = "\\t"
      control[sprintf("%c", 12)] = "\\f"
      control[sprintf("%c", 13)] = "\\r"
    }
    {
      if (NR > 1) printf "\\n"
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "\\") printf "\\\\"
        else if (c == "\"") printf "\\\""
        else if (c in control) printf "%s", control[c]
        else printf "%s", c
      }
    }'
}

# Read the first string value of KEY from JSON on stdin (unescapes \" and \\ only,
# which is all ids, session ids and prompts need here).
cp_json_string() {
  awk -v key="$1" '
    { input = input $0 "\n" }
    END {
      if (!match(input, "\"" key "\"[[:space:]]*:[[:space:]]*\"")) exit 1
      v = ""; esc = 0
      for (i = RSTART + RLENGTH; i <= length(input); i++) {
        c = substr(input, i, 1)
        if (esc) { if (c == "n") c = "\n"; v = v c; esc = 0; continue }
        if (c == "\\") { esc = 1; continue }
        if (c == "\"") { printf "%s", v; exit 0 }
        v = v c
      }
      exit 1
    }' 2>/dev/null
}

# Every value of "id" in a findings document, one per line, in order.
cp_finding_ids() {
  grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/'
}

# --- findings as data ------------------------------------------------------------------
# python3 where it exists, jq otherwise (stock macOS 15+ ships /usr/bin/jq); with
# neither, the repro and memory features switch themselves off and say so.
cp_json_tool() {
  if command -v python3 >/dev/null 2>&1; then printf 'python3'
  elif command -v jq >/dev/null 2>&1; then printf 'jq'
  else printf ''; fi
}

# One finding per line: id<TAB>severity<TAB>category<TAB>where<TAB>problem, with
# whitespace runs squashed so a field never spans lines or tabs.
cp_findings_tsv() {
  case "$(cp_json_tool)" in
    python3)
      python3 -I - "$1" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
c = lambda s: " ".join(str(s or "").split())
for f in d.get("findings", []):
    print("\t".join([c(f.get("id")), c(f.get("severity")), c(f.get("category") or "other"), c(f.get("where")), c(f.get("problem"))]))
PY
      ;;
    jq)
      jq -r '.findings[] | [.id, .severity, (.category // "other"), .where, .problem] | map(tostring | gsub("[[:space:]]+"; " ")) | @tsv' "$1" 2>/dev/null ;;
  esac
}

# Write each finding's repro into DEST/<id>/ (the test file, plus "file" and
# "command"), and print the ids that have one.
cp_repro_extract() {
  local src="$1" dest="$2" id name
  case "$(cp_json_tool)" in
    python3)
      python3 -I - "$src" "$dest" <<'PY' 2>/dev/null
import json, os, re, sys
d = json.load(open(sys.argv[1])); dest = sys.argv[2]
for f in d.get("findings", []):
    r = f.get("repro")
    if not isinstance(r, dict) or not str(r.get("command") or "").strip():
        continue
    i = re.sub(r"[^A-Za-z0-9]", "", str(f.get("id") or ""))
    if not i:
        continue
    name = re.sub(r"[^A-Za-z0-9._-]", "", os.path.basename(str(r.get("file") or ""))).lstrip(".") or "repro.sh"
    p = os.path.join(dest, i); os.makedirs(p, exist_ok=True)
    open(os.path.join(p, name), "w").write(str(r.get("content") or ""))
    open(os.path.join(p, "file"), "w").write(name + "\n")
    open(os.path.join(p, "command"), "w").write(str(r["command"]) + "\n")
    print(i)
PY
      ;;
    jq)
      for id in $(jq -r '.findings[] | select((.repro.command // "") | test("[^[:space:]]")) | .id' "$src" 2>/dev/null); do
        id="$(printf '%s' "$id" | LC_ALL=C tr -cd 'A-Za-z0-9')"; [ -n "$id" ] || continue
        mkdir -p "$dest/$id"
        name="$(jq -r --arg i "$id" '.findings[] | select(.id == $i) | .repro.file // ""' "$src" | head -1)"
        name="$(basename "x/$name" | LC_ALL=C tr -cd 'A-Za-z0-9._-' | sed 's/^\.*//')"; [ -n "$name" ] || name=repro.sh
        jq -r --arg i "$id" '.findings[] | select(.id == $i) | .repro.content // ""' "$src" > "$dest/$id/$name"
        echo "$name" > "$dest/$id/file"
        jq -r --arg i "$id" '.findings[] | select(.id == $i) | .repro.command' "$src" | head -1 > "$dest/$id/command"
        echo "$id"
      done ;;
  esac
}

# Findings outside the change under review, one per line:
# id<TAB>severity<TAB>category<TAB>where<TAB>problem<TAB>fix. A finding with no
# origin (an older reply) counts as part of the change.
cp_preexisting_tsv() {
  case "$(cp_json_tool)" in
    python3)
      python3 -I - "$1" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
c = lambda s: " ".join(str(s or "").split())
for f in d.get("findings", []):
    if f.get("origin") == "preexisting":
        print("\t".join([c(f.get("id")), c(f.get("severity")), c(f.get("category") or "other"), c(f.get("where")), c(f.get("problem")), c(f.get("fix"))]))
PY
      ;;
    jq)
      jq -r '.findings[] | select(.origin == "preexisting") | [.id, .severity, (.category // "other"), .where, .problem, .fix] | map(tostring | gsub("[[:space:]]+"; " ")) | @tsv' "$1" 2>/dev/null ;;
  esac
}

# The verdict for the change alone: "fix" while a blocker or major of the change
# remains, "ship" otherwise (pre-existing defects never hold a change back).
cp_change_verdict() {
  local n
  case "$(cp_json_tool)" in
    python3)
      n="$(python3 -I -c 'import json,sys; print(sum(1 for f in json.load(open(sys.argv[1])).get("findings",[]) if f.get("severity") in ("blocker","major") and f.get("origin") != "preexisting"))' "$1" 2>/dev/null)" ;;
    jq) n="$(jq '[.findings[] | select((.severity == "blocker" or .severity == "major") and .origin != "preexisting")] | length' "$1" 2>/dev/null)" ;;
  esac
  case "$n" in ''|*[!0-9]*) cp_json_string verdict < "$1" || echo '?' ;; 0) echo ship ;; *) echo fix ;; esac
}
