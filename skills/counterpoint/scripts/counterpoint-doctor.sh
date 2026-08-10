#!/usr/bin/env bash
# counterpoint-doctor.sh: what this machine will and will not do.
#
# The loop spans two operating systems, a CLI on a subscription, a config file
# owned by another tool, and two Claude Code hooks. When a turn misbehaves the
# question is almost never "is the code wrong", it is "which of those five is
# missing here" -- and several of them fail quietly. A stock Mac has no
# timeout(1), so before the shell watchdog existed the bound simply did not
# apply; an unwired Stop hook means nothing enforces the loop; a config.toml
# pinned at xhigh is the difference between a two-minute turn and a seven-minute
# one. This prints all of it in one pass.
#
# Usage: counterpoint-doctor.sh
# Exit 0 when the loop can run, 1 when something blocks it. Warnings do not fail.
set -uo pipefail

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./counterpoint-lib.sh
. "$skill_dir/scripts/counterpoint-lib.sh"

home="${COUNTERPOINT_HOME:-$HOME/.counterpoint}"
blockers=0
warnings=0

say()  { printf '  %s\n' "$1"; }
good() { printf '  ok    %s\n' "$1"; }
warn() { warnings=$((warnings + 1)); printf '  warn  %s\n' "$1"; }
stop() { blockers=$((blockers + 1)); printf '  BLOCK %s\n' "$1"; }

echo "counterpoint doctor"
echo

# --- platform ----------------------------------------------------------------
echo "platform"
say "$(uname -s) $(uname -r) ($(uname -m))"
# The version that matters is what `env bash` resolves to, since that is what
# every shebang in the skill picks: on a Mac with no newer bash first in PATH,
# that is /bin/bash 3.2.
env_bash="$(command -v bash || echo none)"
bash_ver="$("$env_bash" -c 'echo "$BASH_VERSION"' 2>/dev/null || echo unknown)"
case "$bash_ver" in
  3.*) good "bash $bash_ver at $env_bash (3.x is supported; the scripts avoid bash-4 syntax)" ;;
  4.*|5.*) good "bash $bash_ver at $env_bash" ;;
  *) warn "could not read a bash version from $env_bash" ;;
esac
echo

# --- the time bound ----------------------------------------------------------
echo "time bound"
tbin="$(cp_timeout_bin)"
tmo="${COUNTERPOINT_CODEX_TIMEOUT:-600}"
if [ "$tmo" = "0" ]; then
  warn "COUNTERPOINT_CODEX_TIMEOUT=0: Codex calls run unbounded, which is how a turn hangs"
elif [ -n "$tbin" ]; then
  good "$tbin(1) present; every Codex call bounded at ${tmo}s"
else
  good "no timeout(1) (normal on macOS); the shell watchdog bounds calls at ${tmo}s"
fi
say "verifier bound: ${COUNTERPOINT_VERIFIER_TIMEOUT:-900}s   retries after a transient failure: ${COUNTERPOINT_CODEX_RETRIES:-1}"
echo

# --- codex -------------------------------------------------------------------
echo "codex"
if ! command -v codex >/dev/null 2>&1; then
  stop "codex is not on PATH. Install the Codex CLI and sign in to the ChatGPT subscription."
else
  good "codex at $(command -v codex) ($(codex --version 2>/dev/null | head -1 || echo 'version unknown'))"
  cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
  if [ -f "$cfg" ]; then
    m="$(cp_cfg_value model)"; e="$(cp_cfg_value model_reasoning_effort)"
    good "config at $cfg (model=${m:-default} effort=${e:-default})"
    # Effort is the single largest latency term in a turn, so it is worth
    # naming rather than leaving to be discovered by a slow run.
    if [ "$e" = "xhigh" ]; then
      say "      xhigh is the slowest setting; plan and plan-review are capped to high automatically"
    fi
    # --ignore-user-config drops MCP servers on purpose: one of them hanging
    # under a networkless sandbox is what burned a nine-minute turn.
    if grep -q '^\[mcp_servers' "$cfg" 2>/dev/null; then
      say "      MCP servers are configured; the critic and planner drop them via --ignore-user-config"
    fi
  else
    warn "no $cfg; Codex defaults apply and no model is re-injected after --ignore-user-config"
  fi
fi
echo

# --- sandbox -----------------------------------------------------------------
echo "sandbox"
# Codex's workspace-write sandbox uses bubblewrap, which cannot start under an
# outer sandbox like gVisor. There the write path and `codex exec review` come
# back empty-handed while still exiting 0, which reads as a pass.
outer=""
[ -d /proc ] && grep -qi 'gvisor' /proc/version 2>/dev/null && outer="gVisor"
if [ -n "$outer" ]; then
  if [ "${COUNTERPOINT_CODEX_BYPASS_SANDBOX:-0}" = "1" ]; then
    good "$outer detected and COUNTERPOINT_CODEX_BYPASS_SANDBOX=1: the write path and code review can see the repo"
  else
    warn "$outer detected: Codex's own sandbox cannot start here, so --write and code review will come back blind. Set COUNTERPOINT_CODEX_BYPASS_SANDBOX=1 (safe only because the outer sandbox is the isolation)."
  fi
else
  good "no outer sandbox detected; Codex's own sandbox is in force"
fi
command -v git >/dev/null 2>&1 && good "git present (codex exec review reads the working diff)" \
  || warn "git missing; the code-review pass has no diff to read"
echo

# --- state -------------------------------------------------------------------
echo "state"
mode="off"
[ -f "$home/mode" ] && mode="$(tr -d '[:space:]' < "$home/mode" 2>/dev/null || echo off)"
case "$mode" in
  small|full) good "toggle: $mode" ;;
  *) say "toggle: off (the loop is dormant; counterpoint-mode.sh small|full arms it)" ;;
esac
if mkdir -p "$home/runs" 2>/dev/null && [ -w "$home/runs" ]; then
  n=0
  for d in "$home"/runs/*/; do [ -d "$d" ] && n=$((n + 1)); done
  sz="$(du -sh "$home/runs" 2>/dev/null | awk '{print $1}')"
  good "$home/runs writable: $n run(s), ${sz:-0}, retention ${COUNTERPOINT_RETENTION_DAYS:-30} day(s)"
else
  stop "cannot write $home/runs; no phase can record that it ran"
fi
echo

# --- enforcement -------------------------------------------------------------
echo "enforcement"
# Without both hooks wired the loop is a suggestion: nothing arms the turn and
# nothing refuses to end it.
settings=""
for c in "$HOME/.claude/settings.json" "$PWD/.claude/settings.json"; do
  [ -f "$c" ] && settings="$settings $c"
done
if [ -z "$settings" ]; then
  warn "no Claude Code settings.json found; the hooks are probably not wired (see SKILL.md)"
else
  for c in $settings; do
    hooked_prompt=0; hooked_stop=0
    grep -q 'counterpoint-hook.sh' "$c" 2>/dev/null && hooked_prompt=1
    grep -q 'counterpoint-stop-hook.sh' "$c" 2>/dev/null && hooked_stop=1
    if [ "$hooked_prompt" = 1 ] && [ "$hooked_stop" = 1 ]; then
      good "both hooks wired in $c"
    elif [ "$hooked_prompt" = 1 ] || [ "$hooked_stop" = 1 ]; then
      warn "only one hook wired in $c (prompt=$hooked_prompt stop=$hooked_stop); the loop is armed or enforced but not both"
    fi
  done
fi
for f in counterpoint-run.sh counterpoint-plan.sh counterpoint-review.sh \
         counterpoint-finalize.sh codex-consult.sh codex-produce.sh; do
  [ -x "$skill_dir/scripts/$f" ] || warn "$f is not executable (chmod +x it)"
done
echo

# --- verdict -----------------------------------------------------------------
if [ "$blockers" -gt 0 ]; then
  echo "verdict: $blockers blocker(s), $warnings warning(s). The loop cannot run as configured."
  exit 1
fi
if [ "$warnings" -gt 0 ]; then
  echo "verdict: usable, with $warnings warning(s) above."
else
  echo "verdict: usable, nothing to flag."
fi
exit 0
