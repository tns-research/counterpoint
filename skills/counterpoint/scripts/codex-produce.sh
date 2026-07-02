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
#     role.
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
#   printf '%s' "$PROMPT" | codex-produce.sh [-m MODEL] [-C DIR] [--write SCRATCHDIR]
#
# Exit code is Codex's; on success the clean final message is on stdout.
set -euo pipefail

model=""
cd_dir="$PWD"
write_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m) model="$2"; shift 2 ;;
    -C) cd_dir="$2"; shift 2 ;;
    --write) write_dir="$2"; shift 2 ;;
    *) echo "codex-produce.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

if [ -t 0 ]; then
  echo "codex-produce.sh: expects the assembled produce-prompt on stdin" >&2
  exit 2
fi

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
cfg_model="$(awk '/^\[/{exit} /^[[:space:]]*model[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,""); gsub(/"/,""); print; exit}' "$cfg" 2>/dev/null || true)"
cfg_reasoning="$(awk '/^\[/{exit} /^[[:space:]]*model_reasoning_effort[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,""); gsub(/"/,""); print; exit}' "$cfg" 2>/dev/null || true)"

add_model_config() {
  if [ -n "$model" ]; then
    args+=(-m "$model")
  elif [ -n "$cfg_model" ]; then
    args+=(-c "model=\"$cfg_model\"")
  fi
  [ -n "$cfg_reasoning" ] && args+=(-c "model_reasoning_effort=\"$cfg_reasoning\"")
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
else
  # Text emission is context-parity work over the inlined prompt context.
  # Ignore user config to drop MCP servers, then re-inject model defaults.
  args=(exec -s read-only --skip-git-repo-check --color never --ignore-user-config -C "$cd_dir" -o "$out")
  add_model_config
fi
[ -n "$write_dir" ] && [ -n "$model" ] && args+=(-m "$model")
args+=(-)

codex "${args[@]}" >&2

cat "$out"
