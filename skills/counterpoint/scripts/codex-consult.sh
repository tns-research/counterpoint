#!/usr/bin/env bash
# codex-consult.sh: one read-only Codex pass on the ChatGPT subscription.
# The assembled prompt (original request + inlined resources + the draft, per
# the context parity contract) is read from stdin. Codex runs sandboxed
# read-only so a consult call can never edit files. Only the final message is
# printed to stdout; reasoning/progress go to stderr.
#
# Usage:
#   printf '%s' "$PROMPT" | codex-consult.sh [-m MODEL] [-e EFFORT] [-C DIR]
#
# -e caps the reasoning effort for this pass (see cp_effort_min): it can lower
# the configured effort for a cheap phase, never raise it.
#
# Exit code: 0 on success with the clean final message on stdout. 124 means the
# call hit the time bound; 3 means Codex returned an empty final message. Both
# are failures the caller must surface rather than treat as a critique.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./counterpoint-lib.sh
. "$script_dir/counterpoint-lib.sh"

model=""
effort_cap=""
cd_dir="$PWD"
while [ $# -gt 0 ]; do
  case "$1" in
    -m) model="$2"; shift 2 ;;
    -e) effort_cap="$2"; shift 2 ;;
    -C) cd_dir="$2"; shift 2 ;;
    *) echo "codex-consult.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

if [ -t 0 ]; then
  echo "codex-consult.sh: expects the assembled prompt on stdin" >&2
  exit 2
fi

# mktemp with no template is a GNU extension; BSD mktemp exits on it, which
# would have made every Codex call fail on a stock Mac. cp_mktemp passes one.
out="$(cp_mktemp out)"
# The prompt is buffered to a file rather than piped straight through: stdin is a
# pipe, a retry cannot re-read it, and the second attempt would otherwise reach
# Codex empty.
prompt_file="$(cp_mktemp prompt)"
trap 'rm -f "$out" "$prompt_file"' EXIT
cat > "$prompt_file"

# Parity contract, and the gVisor hang fix (see eng/07): a read-only critic must
# reason from the inlined parity context only. The user's config.toml
# can register MCP servers (e.g. a Zo web-search server) whose web tools Codex may
# call mid-critique; under a networkless sandbox those calls hang and burn the whole
# turn, so critique.txt comes back empty. --ignore-user-config drops every MCP
# server generically. It also drops the user's model/reasoning defaults, so
# re-inject those from the config (an explicit -m still wins) to avoid a silent
# model downgrade.
cfg_model="$(cp_cfg_value model)"
cfg_reasoning="$(cp_cfg_value model_reasoning_effort)"
effort="$cfg_reasoning"
[ -n "$effort_cap" ] && effort="$(cp_effort_min "$effort_cap" "$cfg_reasoning")"

args=(exec -s read-only --skip-git-repo-check --color never --ignore-user-config -C "$cd_dir" -o "$out")
if [ -n "$model" ]; then
  args+=(-m "$model")
elif [ -n "$cfg_model" ]; then
  args+=(-c "model=\"$cfg_model\"")
fi
[ -n "$effort" ] && args+=(-c "model_reasoning_effort=\"$effort\"")
args+=(-)

# Bounded in time, retried once on a transient failure, and an empty final
# message is a failure rather than a silent pass. Progress/reasoning to stderr;
# the final message is captured via -o.
rc=0
cp_codex_exec "$out" --stdin "$prompt_file" -- "${args[@]}" || rc=$?
if [ "$rc" != 0 ]; then
  cat "$out"
  exit "$rc"
fi

cat "$out"
