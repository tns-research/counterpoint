#!/usr/bin/env bash
# counterpoint-hook.sh: the always-on toggle, realized as a UserPromptSubmit hook.
#
# Claude Code runs this once per user message. It reads the toggle
# (~/.counterpoint/mode). When the toggle is "off" (or absent) it stays silent and
# the turn is ordinary single-model Claude Code. When the toggle is "small"/"full"
# it prints an instruction block on stdout, which Claude Code appends to the
# turn's context, telling the orchestrator to run the counterpoint pipeline at
# that depth. That injection is what makes the loop automatic with no slash
# command typed.
#
# The toggle is the single source of truth. On every prompt this hook stamps a
# fresh turn id (current-turn) so the Stop hook can tie a run to the turn; that is
# the only per-turn state it writes, and no copy of the mode is persisted. The
# Stop hook re-reads the toggle live, so nothing can go stale and contradict it.
# (An earlier build froze the mode into a per-turn marker, which could still say
# full after the toggle went off: the on-and-off incoherence.) A manual
# /counterpoint is just the slash command loading the skill; we detect it only to
# avoid injecting the directive on top of it when the toggle is already on.
#
# Wired in settings.json under hooks.UserPromptSubmit. Exit 0 always (a hook
# failure must never block the user's prompt).
set -uo pipefail

home="${COUNTERPOINT_HOME:-$HOME/.counterpoint}"
state_file="$home/mode"
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mode="off"
[ -f "$state_file" ] && mode="$(tr -d '[:space:]' < "$state_file" 2>/dev/null || echo off)"

# Read the hook payload once. We detect a manual /counterpoint only to avoid
# double-injecting on top of the slash command (which already loads the skill)
# when the toggle is on. The manual path is not separately armed: the slash
# command runs the loop for that turn on its own.
payload="$(cat 2>/dev/null || true)"
manual=0
case "$payload" in
  *"/counterpoint"*) manual=1 ;;
esac

# Effective mode for THIS turn comes only from the toggle. Single source of truth.
effective="off"
case "$mode" in
  small|full) effective="$mode" ;;
esac

# Stamp a fresh turn id every prompt so the run command and the Stop hook always
# see the CURRENT turn (v2 enforcement, see eng/07). One stamp per user prompt.
#
# Deliberately not `date +%s%N`: BSD date has no %N and emits a literal "N", so
# on macOS every id was "<seconds>N-<pid>" and only stayed unique by accident.
# Second + pid + $RANDOM is unique on both platforms for the property that is
# actually needed, which is that two turns never collide. The hook stays
# dependency-free (it must never fail and block a prompt), so this is inline
# rather than sourced from counterpoint-lib.sh.
mkdir -p "$home"
turn_id="$(date +%s)-$$-${RANDOM:-0}"
printf '%s\n' "$turn_id" > "$home/current-turn"

# Purge any per-turn markers an older build left on disk. Enforcement is now
# toggle-only, read live by the Stop hook, so no per-turn copy of the mode exists
# to go stale -- that frozen copy was the on-and-off incoherence.
rm -f "$home/current-turn-mode" "$home/current-turn-manual"

# Toggle off: dormant, ordinary single-model turn.
[ "$effective" = "off" ] && exit 0

# Toggle on but the user typed /counterpoint: the slash command already loads the
# skill, so we do NOT also inject the directive (that would double-fire).
[ "$manual" = 1 ] && exit 0

if [ "$effective" = "full" ]; then
  depth_line="run the joint planning front-end first (both models plan, reconcile into one agreed plan, assign roles), then produce, critique with full context parity, settle on the verification ladder, revise, and deliver"
else
  depth_line="produce, critique with full context parity, settle on the verification ladder, revise, and deliver (no joint planning front-end)"
fi

# Uppercased by hand, not with ${effective^^}: that operator is bash 4, and
# macOS ships bash 3.2 as /bin/bash, which `env bash` finds on any Mac without a
# newer one earlier in PATH. There the expansion raised "bad substitution", the
# whole heredoc failed, the hook still exited 0, and the directive was never
# injected -- counterpoint looked installed and silently did nothing on macOS.
case "$effective" in
  small) effective_uc="SMALL" ;;
  full)  effective_uc="FULL" ;;
  *)     effective_uc="$effective" ;;
esac

cat <<EOF
[counterpoint: ON, mode=${effective}]
The counterpoint loop is active for this turn. Before answering, run the
counterpoint skill at ${effective_uc} depth on this request: ${depth_line}.
Follow ${skill_dir}/SKILL.md for the choreography. Run the audited half through
the command so the loop is enforced, not just narrated: save the producer's
draft to a file, then call

  ${skill_dir}/scripts/counterpoint-run.sh --mode ${effective} \\
    --task "<short>" --draft <draft-file> --prompt <prompt-file> \\
    --resource <each resolved AGENTS.md/skill/file> [--code] [--verifier "<cmd>"]

It re-resolves context parity from source, runs the read-only Codex critique
(and the verifier on code), and writes the per-turn run artifact (draft.md +
log.txt). Revise from the returned critique, then finalize with

  ${skill_dir}/scripts/counterpoint-finalize.sh --final <revised-file> \\
    --caught "<what the critique changed, or 'nothing, draft held'>"

which writes result.md (the shipped, revised deliverable) and resolves the log.
A Stop hook will refuse to end the turn until both the run artifact and result.md
exist AND the critique actually succeeded, so the loop cannot be silently skipped
and a failed Codex call cannot pass for one that ran. If a phase reports a
failure, re-run it: a failed call is not counted as a round. This is a bounded single exchange;
do not loop beyond the capped mini-loop.
EOF

if [ "$effective" = "full" ]; then
  cat <<EOF
In full mode two more phases are enforced before the critique, so the Stop hook
requires the joint plan, the plan review, the critique, and result.md this turn
(the first three below, then finalize as above). Run:
  ${skill_dir}/scripts/counterpoint-plan.sh   (F1: both models plan; writes plan_codex.txt.
                                  Prefer --launch ... then --collect, so Codex plans
                                  while you draft yours instead of after it)
  ${skill_dir}/scripts/counterpoint-review.sh (F3: the non-producer reviews the reconciled plan;
                                  writes plan_review.txt. Codex reviewer = read-only
                                  Codex call; Opus reviewer = in-session, no Codex call)
Score the two plans (F2) to assign the producer, reconcile into one agreed plan,
run the F3 review, let the producer arbitrate it, then produce and run the
critique. See ${skill_dir}/SKILL.md for the exact flags.
EOF
fi
exit 0
