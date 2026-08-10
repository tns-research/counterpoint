#!/usr/bin/env bash
# codex-produce.sh: one Codex pass on the ChatGPT subscription, in the PRODUCER
# role. Sibling to codex-consult.sh (the read-only critic). Roles are symmetric
# in counterpoint, so when the arbitrage step assigns Codex the producer role,
# Codex must be able to emit the deliverable; read-only is the critic's flag and
# would be wrong here.
#
# The assembled produce-prompt (original request + inlined resources + agreed
# plan, per the context parity contract) is read from stdin. Only Codex's final
# message is printed to stdout; reasoning/progress go to stderr.
#
# Two modes:
#   default (text emission): -s read-only, Codex emits the deliverable as text on
#     stdout and the orchestrator places it. Safe to keep read-only because Codex
#     is only producing characters and never touches the tree.
#   --write DIR (heavy multi-file production): -s workspace-write scoped to DIR,
#     Codex writes the files directly into that scratch directory. This is the one
#     place a Codex subprocess may write, and only because it holds the producer
#     role. The working root is the scratch dir, so the repo the task is about is
#     handed over separately with --add-dir (see below), otherwise the producer
#     starts blind to the tree it is supposed to change.
#
# Sandbox note: Codex's workspace-write sandbox uses bubblewrap, which fails on
# some externally-sandboxed hosts (e.g. gVisor: "bwrap: loopback: Failed
# RTM_NEWADDR"). On such a host, set COUNTERPOINT_CODEX_BYPASS_SANDBOX=1 to run
# --write with --dangerously-bypass-approvals-and-sandbox instead. Only do this
# when an outer sandbox already isolates the machine, because it gives Codex full
# access for that one producer call. Text-emission (the default mode) never needs
# this; it stays read-only.
#
# Usage:
#   printf '%s' "$PROMPT" | codex-produce.sh [-m MODEL] [-e EFFORT] [-C DIR] \
#     [--write SCRATCHDIR] [--add-dir DIR]
#
# -C is the repo/working context (default: $PWD). In --write mode Codex is
# anchored to SCRATCHDIR and -C is passed through as --add-dir so it can still
# read the project. --add-dir adds a further directory.
#
# Exit code: 0 on success with the clean final message on stdout. 124 means the
# call hit the time bound; 3 means Codex returned an empty final message.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./counterpoint-lib.sh
. "$script_dir/counterpoint-lib.sh"

model=""
effort_cap=""
cd_dir="$PWD"
write_dir=""
extra_dirs=()
while [ $# -gt 0 ]; do
  case "$1" in
    -m) model="$2"; shift 2 ;;
    -e) effort_cap="$2"; shift 2 ;;
    -C) cd_dir="$2"; shift 2 ;;
    --write) write_dir="$2"; shift 2 ;;
    --add-dir) extra_dirs+=("$2"); shift 2 ;;
    *) echo "codex-produce.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

if [ -t 0 ]; then
  echo "codex-produce.sh: expects the assembled produce-prompt on stdin" >&2
  exit 2
fi

out="$(mktemp)"
# The prompt is buffered to a file rather than piped straight through: stdin is a
# pipe, a retry cannot re-read it, and the second attempt would otherwise reach
# Codex empty.
prompt_file="$(mktemp)"
trap 'rm -f "$out" "$prompt_file"' EXIT
cat > "$prompt_file"

cfg_model="$(cp_cfg_value model)"
cfg_reasoning="$(cp_cfg_value model_reasoning_effort)"
effort="$cfg_reasoning"
[ -n "$effort_cap" ] && effort="$(cp_effort_min "$effort_cap" "$cfg_reasoning")"

add_model_config() {
  if [ -n "$model" ]; then
    args+=(-m "$model")
  elif [ -n "$cfg_model" ]; then
    args+=(-c "model=\"$cfg_model\"")
  fi
  [ -n "$effort" ] && args+=(-c "model_reasoning_effort=\"$effort\"")
}

if [ -n "$write_dir" ]; then
  mkdir -p "$write_dir"
  if [ "${COUNTERPOINT_CODEX_BYPASS_SANDBOX:-0}" = "1" ]; then
    # Externally-sandboxed host where bubblewrap fails: the outer sandbox is the
    # isolation, so bypass Codex's own and anchor it to the scratch dir.
    args=(exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --color never -C "$write_dir" -o "$out")
  else
    # Heavy production: Codex writes files into the scratch dir it is anchored to.
    args=(exec -s workspace-write --skip-git-repo-check --color never -C "$write_dir" -o "$out")
  fi
  # The producer is anchored to the scratch dir, so hand it the project it is
  # producing against. Without this it can only see an empty directory.
  [ "$cd_dir" != "$write_dir" ] && args+=(--add-dir "$cd_dir")
  for d in ${extra_dirs+"${extra_dirs[@]}"}; do args+=(--add-dir "$d"); done
  # --write keeps the user config (the producer may legitimately need its tools),
  # so only an explicit -m/-e is applied here.
  [ -n "$model" ] && args+=(-m "$model")
  [ -n "$effort_cap" ] && args+=(-c "model_reasoning_effort=\"$effort\"")
else
  # Text emission is context-parity work over the inlined prompt context.
  # Ignore user config to drop MCP servers, then re-inject model defaults.
  args=(exec -s read-only --skip-git-repo-check --color never --ignore-user-config -C "$cd_dir" -o "$out")
  for d in ${extra_dirs+"${extra_dirs[@]}"}; do args+=(--add-dir "$d"); done
  add_model_config
fi
args+=(-)

rc=0
cp_codex_exec "$out" --stdin "$prompt_file" -- "${args[@]}" || rc=$?
if [ "$rc" != 0 ]; then
  cat "$out"
  exit "$rc"
fi

cat "$out"
