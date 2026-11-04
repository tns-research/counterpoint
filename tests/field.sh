#!/usr/bin/env bash
# v3.1: the fixes that came out of a user's first weeks on real payment and SQL
# work. File lists that lost all but their first file, reviews that dug into old
# code forever, repros that could not see the database, and facts Codex could not know.
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# --- every file of a list reaches Codex ---------------------------------------------
printf 'one\n' > w1.sql; printf 'two\n' > w2.sql; printf 'three\n' > w3.sql
printf 'ctx one\n' > c1.md; printf 'ctx two\n' > c2.md
out="$("$CP" review --turn m1 --ask x --draft w1.sql w2.sql w3.sql --context c1.md c2.md 2>&1)"; rc=$?
ok "a review of three files exits 0" "$rc" 0
p="$(cat "$COUNTERPOINT_FAKE_LOG.stdin")"
has "the first file is sent" "$p" "### w1.sql"
has "the second file is sent" "$p" "### w2.sql"
has "the third file is sent" "$p" "### w3.sql"
has "every context file is sent" "$p" "### c2.md"
has "the author is told what Codex receives" "$out" "Codex receives: 3 work files (w1.sql"
has "with the context files" "$out" "2 context files"
out="$("$CP" review --turn m1b --draft w1.sql --draft w2.sql --ask x 2>&1)"
has "a repeated --draft adds up" "$(cat "$COUNTERPOINT_FAKE_LOG.stdin")" "### w2.sql"
out="$("$CP" review --turn m2 --ask x stray --draft w1.sql 2>&1)"; rc=$?
ok "a stray argument is refused" "$rc" 2
has "and named" "$out" "unexpected argument 'stray'"
out="$("$CP" review --turn m2 --draft --ask x 2>&1)"; rc=$?
ok "--draft with no file is refused" "$rc" 2
out="$("$CP" review --turn m2 --ask x --draft w1.sql missing.sql 2>&1)"; rc=$?
ok "a missing file in the list is refused" "$rc" 2
has "by name" "$out" "no such file: missing.sql"
head -c 450000 /dev/zero | tr '\0' 'x' > big.txt
out="$("$CP" review --turn m3 --ask x --draft big.txt 2>&1)"
has "a cut file is announced" "$out" "WARNING big.txt was cut to its first"

# --- project facts --------------------------------------------------------------------
mkdir -p proj && (cd proj && git init -q && printf 'select 1;\n' > m.sql && git add m.sql && git -c user.email=a@b -c user.name=a commit -qm i && echo 'select 2;' >> m.sql)
out="$("$CP" facts -C proj 2>&1)"
has "facts start empty" "$out" "no facts yet"
"$CP" facts add migration 042 is applied in production -C proj >/dev/null 2>&1
has "a fact is recorded" "$("$CP" facts -C proj 2>&1)" "migration 042 is applied in production"
out="$("$CP" review --turn f1 --ask x --diff -C proj 2>&1)"
p="$(cat "$COUNTERPOINT_FAKE_LOG.stdin")"
has "facts go into the review" "$p" "## Project facts"
has "verbatim" "$p" "migration 042 is applied in production"
has "and the manifest says so" "$out" "1 facts file"
"$CP" plan --turn f1 --ask x -C proj >/dev/null 2>&1
has "facts go into the plan too" "$(cat "$COUNTERPOINT_FAKE_LOG.stdin")" "migration 042"
COUNTERPOINT_FACTS=0 "$CP" review --turn f2 --ask x --diff -C proj >/dev/null 2>&1
case "$(cat "$COUNTERPOINT_FAKE_LOG.stdin")" in *"Project facts"*) r=sent ;; *) r=absent ;; esac
ok "COUNTERPOINT_FACTS=0 leaves them out" "$r" absent
"$CP" review --turn f3 --ask x --draft w1.sql >/dev/null 2>&1
case "$(cat "$COUNTERPOINT_FAKE_LOG.stdin")" in *"migration 042"*) r=leaked ;; *) r=separate ;; esac
ok "another project does not see them" "$r" separate
"$CP" facts clear -C proj >/dev/null 2>&1
has "facts clear empties them" "$("$CP" facts -C proj 2>&1)" "no facts yet"

# --- pre-existing defects and the stopping rule ----------------------------------------
pre_reply='{"verdict":"fix","summary":"s","findings":[{"id":"F1","severity":"major","category":"security","origin":"preexisting","where":"old.php:10","problem":"old hole","evidence":"e","fix":"check rights","repro":null},{"id":"F2","severity":"minor","category":"clarity","origin":"change","where":"m.sql:2","problem":"name","evidence":"e","fix":"rename","repro":null}]}'
export COUNTERPOINT_FAKE_REPLY="$pre_reply"
out="$("$CP" review --turn p1 --ask x --diff -C proj 2>&1)"
has "a pre-existing finding is tagged" "$out" "F1 [major/security, PRE-EXISTING]"
has "the author is told it needs no ledger line" "$out" "pre-existing: 1 finding(s) outside this change"
has "and that nothing blocks the change" "$out" "stop: nothing blocks this change"
has "the prompt asks for the origin" "$(cat "$COUNTERPOINT_FAKE_LOG.stdin")" '"preexisting" when it sits in code the work did not touch'
printf 'F2 applied\n' > lp.md
printf '# tasks\n' > tasks.md
out="$("$CP" done --turn p1 --final proj/m.sql --ledger lp.md --backlog tasks.md 2>&1)"; rc=$?
ok "done accepts a ledger without the pre-existing finding" "$rc" 0
has "counts it deferred" "$out" "1 applied, 0 rejected, 1 deferred"
has "the change verdict is ship" "$out" "final verdict: ship"
has "and points to the backlog" "$out" "filed as separate tasks: tasks.md"
has "the backlog gets the task" "$(cat tasks.md)" "- [ ] F1 [major/security] old.php:10: old hole (suggested fix: check rights)"
"$CP" done --turn p1 --final proj/m.sql --ledger lp.md --backlog tasks.md >/dev/null 2>&1
ok "a second done does not file it twice" "$(grep -c 'old hole' tasks.md)" 1
hist="$(cat "$COUNTERPOINT_HOME"/projects/*/history.jsonl)"
has "memory records it as deferred, pre-existing" "$hist" '"disposition":"deferred","reason":"pre-existing, outside this change"'
printf 'F1 rejected: not reachable\n' > lp2.md
out="$("$CP" review --turn p2 --ask x --diff -C proj 2>&1)"
out="$("$CP" done --turn p2 --final proj/m.sql --ledger lp2.md 2>&1)"; rc=$?
ok "a change finding without a line is still refused" "$rc" 2
has "by id" "$out" "ledger has no line for F2"
change_reply='{"verdict":"fix","summary":"s","findings":[{"id":"F1","severity":"major","category":"correctness","origin":"change","where":"m.sql:2","problem":"p","evidence":"e","fix":"f","repro":null}]}'
export COUNTERPOINT_FAKE_REPLY="$change_reply"
out="$("$CP" review --turn p3 --ask x --diff -C proj 2>&1)"
case "$out" in *"stop: nothing blocks"*) r=said ;; *) r=quiet ;; esac
ok "no stop line while the change has a major" "$r" quiet
unset COUNTERPOINT_FAKE_REPLY

# --- at most three reviews per turn ---------------------------------------------------
for i in 1 2 3; do "$CP" review --turn r1 --ask x --draft w1.sql >/dev/null 2>&1; done
out="$("$CP" review --turn r1 --ask x --draft w1.sql 2>&1)"; rc=$?
ok "a fourth review is refused" "$rc" 2
has "with the way out" "$out" "pass --again"
out="$("$CP" review --turn r1 --ask x --draft w1.sql --again 2>&1)"; rc=$?
ok "--again runs it" "$rc" 0
out="$(COUNTERPOINT_MAX_REVIEWS=0 "$CP" review --turn r1 --ask x --draft w1.sql 2>&1)"; rc=$?
ok "COUNTERPOINT_MAX_REVIEWS=0 lifts the cap" "$rc" 0
for i in 1 2 3; do COUNTERPOINT_FAKE_BEHAVIOR=hang "$CP" review --turn r2 --ask x --draft w1.sql --bg >/dev/null 2>&1; done
out="$("$CP" review --turn r2 --ask x --draft w1.sql --bg 2>&1)"; rc=$?
ok "reviews still running count toward the cap" "$rc" 2
for d in "$COUNTERPOINT_HOME"/turns/r2/runs/*; do echo failed:1 > "$d/status"; done
out="$("$CP" review --turn r2 --ask x --draft w1.sql 2>&1)"; rc=$?
ok "failed reviews do not, so a retry runs" "$rc" 0
"$CP" recheck --turn r1 --draft w1.sql --ledger lp.md >/dev/null 2>&1; rc=$?
ok "a recheck is never capped" "$rc" 0

# --- a fix the repro cannot check: verified by hand, per finding ------------------------
mkdir -p q && (cd q && git init -q && printf '#!/bin/sh\necho $(( $1 - $2 ))\n' > calc.sh && git add calc.sh && git -c user.email=a@b -c user.name=a commit -qm i && echo '# wip' >> calc.sh)
body='if [ -f fixed.marker ]; then echo "needs db"; exit 3; fi; r="$(sh ./calc.sh 2 3)"; if [ "$r" = 5 ]; then echo "COUNTERPOINT-REPRO: PASS"; exit 0; fi; echo "COUNTERPOINT-REPRO: FAIL"; exit 1'
export COUNTERPOINT_FAKE_REPLY="$(python3 -c 'import json,sys; print(json.dumps({"verdict":"fix","summary":"s","findings":[{"id":"F1","severity":"major","category":"correctness","origin":"change","where":"calc.sh:2","problem":"p","evidence":"e","fix":"f","repro":{"file":"r.sh","command":"bash \"$REPRO\"","content":sys.argv[1]}}]}))' "$body")"
out="$("$CP" review --turn v1 --ask x --diff -C q 2>&1)"
has "the bug is reproduced" "$out" "repro F1: REPRODUCED"
printf '#!/bin/sh\necho $(( $1 + $2 ))\n' > q/calc.sh; : > q/fixed.marker
out="$("$CP" verify --turn v1 2>&1)"
has "after the fix the test cannot run" "$out" "after the fix: inconclusive"
printf 'F1 applied\n' > lv.md
out="$("$CP" done --turn v1 --final q/calc.sh --ledger lv.md 2>&1)"; rc=$?
ok "done refuses a fix nobody checked" "$rc" 2
has "and says how to record a hand check" "$out" "F1 applied, verified: <how>"
printf 'F1 applied, verified: ran calc.sh 2 3 against the staging copy, got 5\n' > lv.md
out="$("$CP" done --turn v1 --final q/calc.sh --ledger lv.md 2>&1)"; rc=$?
ok "done accepts the finding on the stated check" "$rc" 0
has "and says so" "$out" "accepted on your check: ran calc.sh 2 3"
has "the summary counts it" "$out" "1 applied (1 verified by hand)"
has "the turn stays reviewed" "$(cat "$COUNTERPOINT_HOME/turns/v1/done")" "status=reviewed"
has "memory keeps the check" "$(cat "$COUNTERPOINT_HOME"/projects/*/history.jsonl)" 'verified: ran calc.sh 2 3'
printf 'F1 applied, verified:\n' > lv2.md
rm -f q/fixed.marker; printf '#!/bin/sh\necho $(( $1 - $2 ))\n' > q/calc.sh
"$CP" review --turn v2 --ask x --diff -C q >/dev/null 2>&1
"$CP" verify --turn v2 >/dev/null 2>&1; : > q/fixed.marker
out="$("$CP" done --turn v2 --final q/calc.sh --ledger lv2.md 2>&1)"; rc=$?
ok "an empty verified: is not a check" "$rc" 2
printf 'F1 applied, verified: checked by hand\n' > lv3.md
out="$("$CP" done --turn v2 --final q/calc.sh --ledger lv3.md 2>&1)"; rc=$?
ok "a still-failing repro can be overridden on a stated check" "$rc" 0
has "with a warning" "$out" "WARNING F1: its repro still fails after the fix"
rm -f q/fixed.marker
has "the repro prompt asks for live checks instead of fake databases" "$(cat "$COUNTERPOINT_HOME/turns/v1/runs/01-review/prompt.md")" "Needs a live check:"

# --- a test database for the repros, by explicit name only ------------------------------
envbody='if [ "${TEST_DB_URL:-}" = "pg://test" ]; then echo "COUNTERPOINT-REPRO: FAIL"; exit 1; fi; echo "COUNTERPOINT-REPRO: PASS"'
export COUNTERPOINT_FAKE_REPLY="$(python3 -c 'import json,sys; print(json.dumps({"verdict":"fix","summary":"s","findings":[{"id":"F1","severity":"major","category":"correctness","origin":"change","where":"calc.sh:2","problem":"p","evidence":"e","fix":"f","repro":{"file":"r.sh","command":"bash \"$REPRO\"","content":sys.argv[1]}}]}))' "$envbody")"
TEST_DB_URL=pg://test "$CP" review --turn e1 --ask x --diff -C q >/dev/null 2>&1
ok "an unlisted variable never reaches a repro" "$(cat "$COUNTERPOINT_HOME/turns/e1/runs/01-review/repro/F1/before")" passes
TEST_DB_URL=pg://test COUNTERPOINT_REPRO_ENV_PASSTHROUGH=TEST_DB_URL "$CP" review --turn e2 --ask x --diff -C q >/dev/null 2>&1
ok "a listed one does" "$(cat "$COUNTERPOINT_HOME/turns/e2/runs/01-review/repro/F1/before")" fails
TEST_DB_URL=pg://test COUNTERPOINT_REPRO_ENV_PASSTHROUGH=TEST_DB_URL "$CP" review --turn e3 --ask x --draft w1.sql >/dev/null 2>&1
case "$(cat "$COUNTERPOINT_FAKE_LOG.env")" in *TEST_DB_URL*) r=leaked ;; *) r=clean ;; esac
ok "and never reaches Codex itself" "$r" clean
unset COUNTERPOINT_FAKE_REPLY

finish
