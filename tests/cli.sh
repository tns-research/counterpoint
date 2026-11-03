#!/usr/bin/env bash
# The CLI end to end against a fake codex: review, bg/wait, recheck, done, log.
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

out="$("$CP" review --turn t1 --brief brief.md --context agents.md --draft a.sh 2>&1)"; rc=$?
ok "foreground review exits 0" "$rc" 0
has "review renders the finding" "$out" "F1 [major] a.sh:1"
has "review shows the verdict" "$out" "verdict: fix"
prompt="$(cat "$COUNTERPOINT_FAKE_LOG.stdin")"
has "prompt carries the request" "$prompt" "the request"
has "prompt carries the context document" "$prompt" "rule one"
has "prompt carries the work" "$prompt" "echo draft"
has "prompt carries the scaffold" "$prompt" "Simplicity first"
args="$(tail -1 "$COUNTERPOINT_FAKE_LOG")"
has "review is read-only" "$args" "-s read-only"
has "review ignores user config (no MCP)" "$args" "--ignore-user-config"
has "review asks for the findings schema" "$args" "findings.json"
has "review defaults to medium effort" "$args" 'model_reasoning_effort="medium"'
ok "thread id recorded" "$(cat "$COUNTERPOINT_HOME/turns/t1/runs/01-review/thread")" "thread-123"

out="$("$CP" done --turn t1 --final a.sh 2>&1)"; rc=$?
ok "done without a ledger is refused" "$rc" 2
printf 'F2 applied\n' > ledger.md
out="$("$CP" done --turn t1 --final a.sh --ledger ledger.md 2>&1)"; rc=$?
ok "done with a ledger missing F1 is refused" "$rc" 2
has "and names the missing id" "$out" "no line for F1"
printf 'F1 rejected\n' > ledger.md
out="$("$CP" done --turn t1 --final a.sh --ledger ledger.md 2>&1)"; rc=$?
ok "a rejection without a reason is refused" "$rc" 2
printf 'F1 rejected: the input never reaches line 1\n' > ledger.md
out="$("$CP" recheck --turn t1 --draft a.sh --ledger ledger.md 2>&1)"; rc=$?
ok "recheck exits 0" "$rc" 0
args="$(tail -1 "$COUNTERPOINT_FAKE_LOG")"
has "recheck resumes the review thread" "$args" "exec resume thread-123"
has "recheck stays read-only" "$args" 'sandbox_mode="read-only"'
has "recheck runs at low effort" "$args" 'model_reasoning_effort="low"'
has "recheck prompt carries the ledger" "$(cat "$COUNTERPOINT_FAKE_LOG.stdin")" "never reaches line 1"
out="$("$CP" done --turn t1 --final a.sh --ledger ledger.md 2>&1)"; rc=$?
ok "done with a complete ledger succeeds" "$rc" 0
has "done prints the summary" "$out" "1 finding(s), 0 applied, 1 rejected"
has "done reports the recheck verdict" "$out" "final verdict: ship"
[ -f "$COUNTERPOINT_HOME/turns/t1/result.md" ] && r=yes || r=no
ok "result.md recorded" "$r" yes
has "log summarises the turn" "$("$CP" log 2>&1)" "1 turns: 1 findings"

# background + wait
out="$("$CP" review --turn t2 --ask "x" --draft a.sh --bg 2>/dev/null)"; rc=$?
ok "--bg returns at once with exit 0" "$rc" 0
has "--bg prints the run dir" "$out" "01-review"
out="$("$CP" wait --turn t2 2>&1)"; rc=$?
ok "wait exits 0" "$rc" 0
has "wait prints the findings" "$out" "F1 [major]"

# failure paths
out="$(COUNTERPOINT_FAKE_BEHAVIOR=fail COUNTERPOINT_CODEX_RETRIES=0 "$CP" review --turn t3 --ask x --draft a.sh 2>&1)"; rc=$?
ok "a failed Codex call exits 4" "$rc" 4
has "and says so loudly" "$out" "!!!"
out="$("$CP" done --turn t3 --final a.sh 2>&1)"; rc=$?
ok "done refuses a turn whose review failed" "$rc" 2
out="$("$CP" done --turn t3 --final a.sh --unreviewed "codex down" 2>&1)"; rc=$?
ok "--unreviewed ships on the record" "$rc" 0
has "and the record says unreviewed" "$(cat "$COUNTERPOINT_HOME/turns/t3/done")" "status=unreviewed"
rm -f "$COUNTERPOINT_FAKE_COUNT"
out="$(COUNTERPOINT_FAKE_BEHAVIOR=flaky "$CP" review --turn t4 --ask x --draft a.sh 2>&1)"; rc=$?
ok "a transient failure is retried" "$rc" 0
out="$(COUNTERPOINT_FAKE_BEHAVIOR=empty COUNTERPOINT_CODEX_RETRIES=0 "$CP" review --turn t5 --ask x --draft a.sh 2>&1)"; rc=$?
ok "an empty answer is a failure" "$rc" 4
s=$(date +%s)
out="$(COUNTERPOINT_FAKE_BEHAVIOR=hang COUNTERPOINT_CODEX_TIMEOUT=2 "$CP" review --turn t6 --ask x --draft a.sh 2>&1)"; rc=$?
ok "a hung Codex call is cut at the bound" "$rc" 4
ok "and its status is timeout" "$(cat "$COUNTERPOINT_HOME/turns/t6/runs/01-review/status")" timeout
[ $(( $(date +%s) - s )) -le 20 ] && r=yes || r=no
ok "within the bound" "$r" yes

# full mode needs a plan
mkdir -p "$COUNTERPOINT_HOME/turns/t7"; echo full > "$COUNTERPOINT_HOME/turns/t7/mode"
"$CP" review --turn t7 --ask x --draft a.sh >/dev/null 2>&1
printf 'F1 applied\n' > l7.md
out="$("$CP" done --turn t7 --final a.sh --ledger l7.md 2>&1)"; rc=$?
ok "full mode refuses done without a plan" "$rc" 2
args_before="$(wc -l < "$COUNTERPOINT_FAKE_LOG")"
"$CP" plan --turn t7 --ask x --context agents.md >/dev/null 2>&1
has "plan is ephemeral and read-only" "$(tail -1 "$COUNTERPOINT_FAKE_LOG")" "--ephemeral -s read-only"
printf 'my plan\n' > mine.md
COUNTERPOINT_COMPARE_ORDER=claude-first "$CP" compare --turn t7 --ask x --mine mine.md >/dev/null 2>&1
"$CP" recheck --turn t7 --draft a.sh --ledger l7.md >/dev/null 2>&1
out="$("$CP" done --turn t7 --final a.sh --ledger l7.md 2>&1)"; rc=$?
ok "full mode done succeeds once planned, compared and rechecked" "$rc" 0
has "full-mode review ran at high effort" "$(sed -n 1p "$COUNTERPOINT_HOME/turns/t7/runs/01-review/effort")" high

# skip, env overrides, produce guard
out="$("$CP" skip --turn t8 "just a question" 2>&1)"; rc=$?
ok "skip closes a turn" "$rc" 0
has "skip records the reason" "$(cat "$COUNTERPOINT_HOME/turns/t8/done")" "just a question"
COUNTERPOINT_MODEL=m-test COUNTERPOINT_FAST=1 COUNTERPOINT_EFFORT=xhigh "$CP" review --turn t9 --ask x --draft a.sh >/dev/null 2>&1
args="$(tail -1 "$COUNTERPOINT_FAKE_LOG")"
has "COUNTERPOINT_MODEL is passed" "$args" "-m m-test"
has "COUNTERPOINT_EFFORT overrides the phase default" "$args" 'model_reasoning_effort="xhigh"'
has "COUNTERPOINT_FAST asks for the priority tier" "$args" 'service_tier="priority"'
out="$("$CP" review --turn t10 --ask x 2>&1)"; rc=$?
ok "review with nothing to review is a usage error" "$rc" 2
out="$("$CP" bogus 2>&1)"; rc=$?
ok "unknown command is a usage error" "$rc" 2
has "help lists the commands" "$("$CP" help)" "recheck"

# session-scoped turn resolution
mkdir -p "$COUNTERPOINT_HOME/sessions/sess-A"; echo turnA > "$COUNTERPOINT_HOME/sessions/sess-A/turn"
CLAUDE_CODE_SESSION_ID=sess-A "$CP" review --ask x --draft a.sh >/dev/null 2>&1
[ -d "$COUNTERPOINT_HOME/turns/turnA/runs/01-review" ] && r=yes || r=no
ok "the session's stamped turn is used without --turn" "$r" yes

# a newer failed review blocks done even when an older one succeeded
"$CP" review --turn r1 --ask x --draft a.sh >/dev/null 2>&1
COUNTERPOINT_FAKE_BEHAVIOR=fail COUNTERPOINT_CODEX_RETRIES=0 "$CP" review --turn r1 --ask x --draft a.sh >/dev/null 2>&1
printf 'F1 applied\n' > lr.md
out="$("$CP" done --turn r1 --final a.sh --ledger lr.md 2>&1)"; rc=$?
ok "done refuses when the newest review failed" "$rc" 2
out="$("$CP" done --turn r1 --final a.sh --ledger lr.md --unreviewed "codex down on re-review" 2>&1)"; rc=$?
ok "--unreviewed overrides it" "$rc" 0
has "and records the turn as unreviewed" "$(cat "$COUNTERPOINT_HOME/turns/r1/done")" "status=unreviewed"

# every completed review's findings need a disposition, not only the latest
"$CP" review --turn r2 --ask x --draft a.sh >/dev/null 2>&1
COUNTERPOINT_FAKE_REPLY='{"verdict":"ship","summary":"clean","findings":[]}' "$CP" review --turn r2 --ask x --draft a.sh >/dev/null 2>&1
: > empty.md
out="$("$CP" done --turn r2 --final a.sh --ledger empty.md 2>&1)"; rc=$?
ok "an earlier review's F1 cannot vanish from the ledger" "$rc" 2

# the thread saved is the answering attempt's, not a failed one's
mkdir -p "$COUNTERPOINT_HOME/turns/r3/runs/01-review"
printf '{"type":"thread.started","thread_id":"dead"}\n{"type":"item.completed","item":{"text":"\\"thread_id\\": \\"quoted\\""}}\n' > ev.jsonl
got="$(grep '"type":"thread.started"' ev.jsonl | tail -1 | (. "$root/skills/counterpoint/lib/core.sh"; cp_json_string thread_id))"
ok "thread id comes from the thread.started event" "$got" dead

# --diff validates its source before spending a Codex call
mkdir -p g && (cd g && git init -q && echo a > f && git add f && git -c user.email=a@b -c user.name=a commit -qm i && echo b > f)
n0="$(cat "$COUNTERPOINT_FAKE_COUNT" 2>/dev/null || echo 0)"
out="$("$CP" review --turn r4 --ask x --diff --base no-such-ref -C g 2>&1)"; rc=$?
ok "an unknown --base is a usage error" "$rc" 2
ok "and no Codex call was made" "$(cat "$COUNTERPOINT_FAKE_COUNT" 2>/dev/null || echo 0)" "$n0"
out="$("$CP" review --turn r5 --ask x --diff -C . 2>&1)"; rc=$?
ok "--diff outside a git repo is a usage error" "$rc" 2
"$CP" review --turn r6 --ask x --diff -C g >/dev/null 2>&1
has "--diff inlines the change" "$(cat "$COUNTERPOINT_FAKE_LOG.stdin")" "+b"

has "a second review is told to continue the numbering" "$(cat "$COUNTERPOINT_HOME/turns/r2/runs/02-review/prompt.md")" "number your findings from F2"
n0="$(cat "$COUNTERPOINT_FAKE_COUNT")"
out="$(GIT_EXTERNAL_DIFF=/bin/false "$CP" review --turn r7 --ask x --diff -C g 2>&1)"; rc=$?
ok "a failing git diff aborts the review" "$rc" 2
ok "before any Codex call" "$(cat "$COUNTERPOINT_FAKE_COUNT")" "$n0"

n0="$(cat "$COUNTERPOINT_FAKE_COUNT")"
out="$(COUNTERPOINT_HOME=relhome GIT_EXTERNAL_DIFF=/bin/false "$CP" review --turn r8 --ask x --diff -C g 2>&1)"; rc=$?
ok "a relative COUNTERPOINT_HOME still catches a failing diff" "$rc" 2
ok "with no Codex call" "$(cat "$COUNTERPOINT_FAKE_COUNT")" "$n0"

COUNTERPOINT_FAKE_REPLY='{"verdict":"fix","summary":"s","unresolved":[],"findings":[{"id":"R1","severity":"major","where":"w","problem":"p","evidence":"e","fix":"f"}]}' "$CP" recheck --turn r9 --draft a.sh --ledger lr.md >/dev/null 2>&1 || true
"$CP" review --turn r10 --ask x --draft a.sh >/dev/null 2>&1
COUNTERPOINT_FAKE_REPLY='{"verdict":"fix","summary":"s","unresolved":[],"findings":[{"id":"R1","severity":"major","where":"w","problem":"p","evidence":"e","fix":"f"}]}' "$CP" recheck --turn r10 --draft a.sh --ledger lr.md >/dev/null 2>&1
printf 'F1 applied\nR1 applied\n' > l10.md
has "the summary counts review and recheck findings" "$("$CP" done --turn r10 --final a.sh --ledger l10.md 2>&1)" "2 finding(s), 2 applied"

finish
