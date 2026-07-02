#!/usr/bin/env bash
# codex-consult.sh: one read-only Codex pass on the ChatGPT subscription.
# The assembled prompt (original request + inlined resources + the draft, per
# the context parity contract) is read from stdin. Codex runs sandboxed
# read-only so a consult call can never edit files. Only the final message is
# printed to stdout; reasoning/progress go to stderr.
#
# Usage:
#   printf '%s' "$PROMPT" | codex-consult.sh [-m MODEL] [-C DIR]
#
# Exit code is Codex's; on success the clean final message is on stdout.
set -euo pipefail

model=""
cd_dir="$PWD"
while [ $# -gt 0 ]; do
  case "$1" in
    -m) model="$2"; shift 2 ;;
    -C) cd_dir="$2"; shift 2 ;;
    *) echo "codex-consult.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

if [ -t 0 ]; then
  echo "codex-consult.sh: expects the assembled prompt on stdin" >&2
  exit 2
fi

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

# Parity contract, and the gVisor hang fix: a read-only critic must
# reason from the inlined parity context only. The user's config.toml
# can register MCP servers (e.g. a Zo web-search server) whose web tools Codex may
# call mid-critique; under a networkless sandbox those calls hang and burn the whole
# turn, so critique.txt comes back empty. --ignore-user-config drops every MCP
# server generically. It also drops the user's model/reasoning defaults, so
# re-inject those from the config (an explicit -m still wins) to avoid a silent
# model downgrade.
cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
cfg_model="$(awk '/^\[/{exit} /^[[:space:]]*model[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,""); gsub(/"/,""); print; exit}' "$cfg" 2>/dev/null || true)"
cfg_reasoning="$(awk '/^\[/{exit} /^[[:space:]]*model_reasoning_effort[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,""); gsub(/"/,""); print; exit}' "$cfg" 2>/dev/null || true)"

args=(exec -s read-only --skip-git-repo-check --color never --ignore-user-config -C "$cd_dir" -o "$out")
if [ -n "$model" ]; then
  args+=(-m "$model")
elif [ -n "$cfg_model" ]; then
  args+=(-c "model=\"$cfg_model\"")
fi
[ -n "$cfg_reasoning" ] && args+=(-c "model_reasoning_effort=\"$cfg_reasoning\"")
args+=(-)

# Progress/reasoning to stderr; final message captured via -o.
codex "${args[@]}" >&2

cat "$out"
