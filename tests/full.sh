#!/usr/bin/env bash
# Full mode: blind plan comparison, producer choice, and the done gates.
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

full_turn() { mkdir -p "$COUNTERPOINT_HOME/turns/$1"; echo full > "$COUNTERPOINT_HOME/turns/$1/mode"; }
printf 'SECRET-NAME-IN-MY-PLAN step one\n' > plan-claude.md
printf 'F1 applied\n' > l.md

# compare needs both plans and the request
full_turn c0
out="$("$CP" compare --turn c0 --ask x --mine plan-claude.md 2>&1)"; rc=$?
ok "compare without a Codex plan is refused" "$rc" 2
"$CP" plan --turn c0 --ask x >/dev/null 2>&1
out="$("$CP" compare --turn c0 --ask x 2>&1)"; rc=$?
ok "compare without --mine is refused" "$rc" 2

# the fake judge scores plan A 6/10 and plan B 4/10
out="$(COUNTERPOINT_COMPARE_ORDER=claude-first "$CP" compare --turn c0 --ask x --mine plan-claude.md 2>&1)"; rc=$?
ok "compare exits 0" "$rc" 0
prompt="$(cat "$COUNTERPOINT_FAKE_LOG.stdin")"
has "both plans reach the judge" "$prompt" "SECRET-NAME-IN-MY-PLAN"
has "the judge gets the Codex plan too" "$prompt" "1. plan step"
case "$prompt" in *plan-claude.md*) r=leaked ;; *) r=blind ;; esac
ok "file names never reach the judge" "$r" blind
args="$(tail -1 "$COUNTERPOINT_FAKE_LOG")"
has "compare is read-only" "$args" "-s read-only"
has "compare asks for the compare schema" "$args" "compare.json"
has "plans are unmasked for Claude" "$out" "Plan A = Claude's plan"
has "totals are shown per author" "$out" "Claude's plan 6/10, Codex's plan 4/10"
has "Claude produces when its plan leads" "$out" "producer: Claude"
ok "decision recorded" "$(cat "$COUNTERPOINT_HOME/turns/c0/runs/02-compare/decision")" claude

# same scores, other order: Codex's plan is A and leads by 2 -> Codex produces
full_turn c1
"$CP" plan --turn c1 --ask x >/dev/null 2>&1
out="$(COUNTERPOINT_COMPARE_ORDER=codex-first "$CP" compare --turn c1 --ask x --mine plan-claude.md 2>&1)"
has "Codex produces when its plan leads by the margin" "$out" "producer: CODEX"
out="$(COUNTERPOINT_COMPARE_ORDER=codex-first COUNTERPOINT_CODEX_MARGIN=3 "$CP" compare --turn c1 --ask x --mine plan-claude.md 2>&1)"
has "a lead under the margin keeps Claude" "$out" "producer: Claude"
out="$(COUNTERPOINT_COMPARE_ORDER=codex-first "$CP" compare --turn c1 --ask x --mine plan-claude.md 2>&1)"

# scores are totalled by counterpoint: duplicates count once, out-of-range ignored
COUNTERPOINT_FAKE_REPLY='{"summary":"s","plans":[{"label":"A","scores":[{"criterion":"insight","score":2,"why":"w"},{"criterion":"insight","score":2,"why":"w"},{"criterion":"risks","score":9,"why":"w"}],"issues":[],"keep":[]},{"label":"B","scores":[],"issues":[],"keep":[]}]}' \
  COUNTERPOINT_COMPARE_ORDER=codex-first "$CP" compare --turn c9 --ask x --mine plan-claude.md --theirs plan-claude.md >/dev/null 2>&1
ok "a padded score sheet totals honestly" "$(sed -n 's/^codex=//p' "$COUNTERPOINT_HOME/turns/c9/runs/01-compare/totals")" 2

# done gates in c1: Codex won, nothing produced by it
"$CP" review --turn c1 --ask x --draft a.sh >/dev/null 2>&1
"$CP" recheck --turn c1 --draft a.sh --ledger l.md >/dev/null 2>&1
out="$("$CP" done --turn c1 --final a.sh --ledger l.md 2>&1)"; rc=$?
ok "done refuses when Codex won production and did not produce" "$rc" 2
has "and says how to proceed" "$out" "--keep-producer"
out="$("$CP" done --turn c1 --final a.sh --ledger l.md --keep-producer "Codex could not run the integration tests" 2>&1)"; rc=$?
ok "--keep-producer closes it on the record" "$rc" 0
has "the reason is recorded" "$(cat "$COUNTERPOINT_HOME/turns/c1/done")" "kept_producer=Codex could not run"

# Codex produced: no Codex review needed (Claude reviews in session)
full_turn c2
"$CP" plan --turn c2 --ask x >/dev/null 2>&1
COUNTERPOINT_COMPARE_ORDER=codex-first "$CP" compare --turn c2 --ask x --mine plan-claude.md >/dev/null 2>&1
"$CP" produce --turn c2 --ask x --plan plan-claude.md >/dev/null 2>&1
out="$("$CP" done --turn c2 --final a.sh 2>&1)"; rc=$?
ok "a Codex-produced full turn closes without a Codex review" "$rc" 0

# review with findings needs a recheck after it
full_turn c3
"$CP" plan --turn c3 --ask x >/dev/null 2>&1
COUNTERPOINT_COMPARE_ORDER=claude-first "$CP" compare --turn c3 --ask x --mine plan-claude.md >/dev/null 2>&1
"$CP" review --turn c3 --ask x --draft a.sh >/dev/null 2>&1
out="$("$CP" done --turn c3 --final a.sh --ledger l.md 2>&1)"; rc=$?
ok "done refuses fixes Codex never confirmed" "$rc" 2
has "and names the recheck" "$out" "counterpoint recheck"
"$CP" recheck --turn c3 --draft a.sh --ledger l.md >/dev/null 2>&1
"$CP" review --turn c3 --ask x --draft a.sh >/dev/null 2>&1
printf 'F1 applied\nF2 applied\n' > l2.md
out="$("$CP" done --turn c3 --final a.sh --ledger l2.md 2>&1)"; rc=$?
ok "a review after the recheck needs its own recheck" "$rc" 2
"$CP" recheck --turn c3 --draft a.sh --ledger l2.md >/dev/null 2>&1
out="$("$CP" done --turn c3 --final a.sh --ledger l2.md 2>&1)"; rc=$?
ok "then done succeeds" "$rc" 0

# a clean review needs no recheck; a missing comparison blocks
full_turn c4
"$CP" plan --turn c4 --ask x >/dev/null 2>&1
COUNTERPOINT_FAKE_REPLY='{"verdict":"ship","summary":"clean","findings":[]}' "$CP" review --turn c4 --ask x --draft a.sh >/dev/null 2>&1
: > empty.md
out="$("$CP" done --turn c4 --final a.sh --ledger empty.md 2>&1)"; rc=$?
ok "full mode refuses done without a comparison" "$rc" 2
COUNTERPOINT_COMPARE_ORDER=claude-first "$CP" compare --turn c4 --ask x --mine plan-claude.md >/dev/null 2>&1
out="$("$CP" done --turn c4 --final a.sh --ledger empty.md 2>&1)"; rc=$?
ok "a clean full-mode review closes without a recheck" "$rc" 0

# the second judge: a fresh Claude session, blind, summed with Codex's scores
J='{"summary":"j","plans":[{"label":"A","scores":[{"criterion":"constraints","score":2,"why":"w"}],"issues":[],"keep":[]},{"label":"B","scores":[{"criterion":"constraints","score":2,"why":"w"},{"criterion":"risks","score":2,"why":"w"},{"criterion":"insight","score":2,"why":"w"},{"criterion":"correctness","score":2,"why":"w"},{"criterion":"specificity","score":2,"why":"w"}],"issues":[],"keep":[]}]}'
full_turn c5
"$CP" plan --turn c5 --ask x >/dev/null 2>&1
out="$(COUNTERPOINT_CLAUDE_JUDGE=1 COUNTERPOINT_FAKE_CLAUDE_REPLY="$J" COUNTERPOINT_COMPARE_ORDER=codex-first CLAUDE_CODE_SESSION_ID=parent-sess \
  "$CP" compare --turn c5 --ask x --mine plan-claude.md 2>&1)"
has "the Claude judge's verdict is shown" "$out" "Claude's judgment (fresh headless session, blind)"
has "scores are summed across both judges" "$out" "Claude's plan 14/20, Codex's plan 8/20"
has "and the sum decides" "$out" "producer: Claude"
cargs="$(cat "$COUNTERPOINT_FAKE_LOG.claude")"
has "the Claude judge has no tools" "$cargs" "--tools"
has "the Claude judge loads no settings or hooks" "$cargs" "--setting-sources"
has "the Claude judge returns the compare schema" "$cargs" '"summary"'
case "$(cat "$COUNTERPOINT_FAKE_LOG.claude.env")" in *CLAUDE_CODE_SESSION_ID*) r=inherits ;; *) r=fresh ;; esac
ok "the Claude judge does not join the calling session" "$r" fresh
has "the Claude judge sees the same blind prompt" "$(cat "$COUNTERPOINT_FAKE_LOG.claude.stdin")" "## Plan B"
out="$(COUNTERPOINT_CLAUDE_JUDGE=1 COUNTERPOINT_FAKE_CLAUDE=fail COUNTERPOINT_COMPARE_ORDER=codex-first "$CP" compare --turn c5 --ask x --mine plan-claude.md 2>&1)"; rc=$?
ok "a failed Claude judge does not fail the comparison" "$rc" 0
has "Codex's judgment then decides alone" "$out" "Codex's plan 6/10"

# start: separate turns without hooks, and the depth done enforces
o1="$(CLAUDE_CODE_SESSION_ID=sessX "$CP" start full 2>&1)"
has "start opens a full turn" "$o1" "(full)"
t1="$(head -1 "$COUNTERPOINT_HOME/sessions/sessX/turn")"
ok "the turn's mode is full" "$(cat "$COUNTERPOINT_HOME/turns/$t1/mode")" full
CLAUDE_CODE_SESSION_ID=sessX "$CP" review --ask x --draft a.sh >/dev/null 2>&1
[ -d "$COUNTERPOINT_HOME/turns/$t1/runs/01-review" ] && r=yes || r=no
ok "commands in the session land in the started turn" "$r" yes
out="$(CLAUDE_CODE_SESSION_ID=sessX "$CP" done --final a.sh --ledger l.md 2>&1)"; rc=$?
ok "a started full turn enforces the full gates" "$rc" 2
sleep 1
CLAUDE_CODE_SESSION_ID=sessX "$CP" start small >/dev/null 2>&1
t2="$(head -1 "$COUNTERPOINT_HOME/sessions/sessX/turn")"
[ "$t1" != "$t2" ] && r=new || r=same
ok "the next task gets a new turn" "$r" new
CLAUDE_CODE_SESSION_ID=sessX "$CP" start full >/dev/null 2>&1
ok "a turn with no run yet is reused" "$(head -1 "$COUNTERPOINT_HOME/sessions/sessX/turn")" "$t2"
ok "and its depth updated" "$(cat "$COUNTERPOINT_HOME/turns/$t2/mode")" full
out="$("$CP" start huge 2>&1)"; rc=$?
ok "start rejects an unknown depth" "$rc" 2

# a fix Codex's recheck disputes cannot stay marked applied
"$CP" review --turn u1 --ask x --draft a.sh >/dev/null 2>&1
COUNTERPOINT_FAKE_REPLY='{"verdict":"fix","summary":"s","unresolved":[{"id":"F1","why":"still octal"}],"findings":[]}' "$CP" recheck --turn u1 --draft a.sh --ledger l.md >/dev/null 2>&1
out="$("$CP" done --turn u1 --final a.sh --ledger l.md 2>&1)"; rc=$?
ok "done refuses a disputed fix still marked applied" "$rc" 2
has "and explains the way out" "$out" "still not fixed"
printf 'F1 rejected: the recheck misreads the base; 0010 is parsed by the guard on line 4\n' > lu.md
out="$("$CP" done --turn u1 --final a.sh --ledger lu.md 2>&1)"; rc=$?
ok "a disputed fix recorded as rejected with a reason closes" "$rc" 0

# small mode is untouched
"$CP" review --turn s1 --ask x --draft a.sh >/dev/null 2>&1
out="$("$CP" done --turn s1 --final a.sh --ledger l.md 2>&1)"; rc=$?
ok "small mode needs no plan, comparison or recheck" "$rc" 0

finish
